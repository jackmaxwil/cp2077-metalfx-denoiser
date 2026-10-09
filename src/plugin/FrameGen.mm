// MetalFX frame interpolation: one generated frame between every two frames the game presents. Built with ARC.
//
// Per real frame N:
// - At the game's MetalFX temporal scaler call (AfterScaler): copy the frame's depth and motion (render resolution)
//   into our own textures, so the next frame cannot overwrite them before the interpolation reads them.
// - At present (Present, on the game's last command buffer): copy the presented image into our history, run
//   MTLFXFrameInterpolator on frames N-1 and N (color: the presented images, post-processing and HUD included; depth and
//   motion: frame N's), and show the generated frame, then frame N at least half a frame interval later
//   (presentDrawable:afterMinimumDuration:), through an overlay layer of our own (a sublayer covering the game's layer,
//   with the game's pixel format and EDR settings and its own three drawables). The game's drawables are never
//   presented and go straight back to its pool: taking extra drawables from the game's layer (three in all) starved it
//   in fullscreen, where each nextDrawable then waited up to its one second timeout (a frame every 1-10 s).
// - Safety valve: three overlay drawable waits over 50 ms in a row turn frame generation off (logged).
// - The presented images must be readable: the layer's framebufferOnly is turned off at the first present (from the
//   next drawable on).
// Camera: near plane, vertical field of view and aspect ratio from NRD's constants (Denoise::Projection; the game renders
// reversed-Z with an infinite far plane, given here as a large finite one).
//
// HUD: generated frames take the HUD's pixels from the real frame (RestoreHud, the game's UI layer as mask, widened by
// its 16x mip over the soft copies the game's HUD composite adds around the HUD).

#include "FrameGen.hpp"
#include "Denoise.hpp"
#include "Logger.hpp"
#include "MetalTrace.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#include <atomic>
#include <cstdlib>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>
#include <map>

namespace {

std::atomic<bool> g_on{false};
std::mutex g_mutex;

id g_interp; // id<MTLFXFrameInterpolator>
id<MTLTexture> g_prev, g_cur, g_out, g_depth, g_motion;
id<MTLTexture> g_prev2; // frame N-2, only while an evaluation runs
bool g_havePrev = false, g_havePrev2 = false;
std::atomic<int> g_evalLeft{0};
int g_evalIndex = 0, g_evalWait = 0, g_evalNormal = 0, g_evalWarm = 0;
id g_evalInterp; // id<MTLFXFrameInterpolator>: its own history (a half-rate stream N-2, N, N+2, ...)
// Jitter given to the interpolator: the render jitter of the frame. The color input is the upscaled (unjittered) image,
// but depth and motion are the jittered render-resolution ones; measured with Evaluate during a turn, the render jitter
// scores about 0.6 dB higher than 0 against the real in-between frame (50-54 dB either way). METALFX_FG_JITTER=0 passes 0.
// Output-size RGBA8 sRGB render targets (UI layers), noted per render pass: texture -> (last present count, passes).
std::mutex g_uiMutex;
struct UiTarget {
    id<MTLTexture> texture;
    uint64_t frame = 0;
    unsigned passes = 0;
};
std::map<void*, UiTarget> g_uiTargets;
std::atomic<NSUInteger> g_outW{0}, g_outH{0};
std::atomic<bool> g_saveUi{false};
int g_uiLogged = 3; // Evaluate logs the UI layers seen at its first three frames
// The HUD: the game draws it into an output-size RGBA8 sRGB layer (with alpha) and composites it over the scene before
// its last pass, so the presented images hold it and the interpolator would warp it with the scene (ghosting in
// motion). After interpolating, the HUD's pixels (the layer's alpha, dilated by a pixel and boosted) are taken from
// this frame's real image instead. (MetalFX's own UI input does not fit: its composited mode returned black even with
// an empty UI texture, and the other mode needs the scene without the HUD, which the game never has in display space.)
// METALFX_FG_UI=0 turns it off.
const bool g_useUi = [] {
    const char* env = std::getenv("METALFX_FG_UI");
    return !(env && *env == '0');
}();

NSString* const kHudSource = @R"(
#include <metal_stdlib>
using namespace metal;
// Snapshots of the UI layer's alpha (level 0, and its 16x mip when it has one), taken in the game's HUD composite.
kernel void fg_ui_copy_array(texture2d_array<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant uint& lod [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x < dst.get_width() && p.y < dst.get_height()) dst.write(float4(src.read(p, 0, lod).a), p);
}
kernel void fg_ui_copy(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       constant uint& lod [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x < dst.get_width() && p.y < dst.get_height()) dst.write(float4(src.read(p, lod).a), p);
}
struct HudParams { uint debug; uint hasLow; };
kernel void fg_hud(texture2d<float, access::read_write> gen [[texture(0)]],
                   texture2d<float, access::read> cur [[texture(1)]],
                   texture2d<float, access::read> ui [[texture(2)]],
                   texture2d<float, access::read> low [[texture(3)]],
                   constant HudParams& h [[buffer(0)]],
                   uint2 p [[thread_position_in_grid]])
{
    if (p.x >= gen.get_width() || p.y >= gen.get_height()) return;
    const int2 s = int2(ui.get_width(), ui.get_height()) - 1;
    float a = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            a = max(a, ui.read(uint2(clamp(int2(p) + int2(x, y), int2(0), s))).r);
    a = saturate(a * 2.0);
    // The game's HUD composite also adds soft offset copies of the HUD (up to about 40 px out, from the UI layer's
    // mips): cover them with the layer's 16x mip, widened by one texel (about +-32 px).
    if (h.hasLow != 0u) {
        const int2 m = int2(low.get_width(), low.get_height()) - 1;
        float b = 0.0;
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x)
                b = max(b, low.read(uint2(clamp(int2(p / 16) + int2(x, y), int2(0), m))).r);
        a = max(a, saturate(b * 4.0));
    }
    if (h.debug != 0u) { gen.write(a > 0.0 ? float4(1, 0, 1, 1) : float4(0, 1, 0, 1), p); return; }
    if (a > 0.0) gen.write(mix(gen.read(p), cur.read(p), a), p);
}
)";
id<MTLComputePipelineState> g_hud, g_uiCopy, g_uiCopyArray;
// The UI layer's alpha as the game's HUD composite read it (HudComposite), for the frame g_uiSnapFrame: reading the
// game's UI layer itself at present time saw it cleared or half redrawn for the next frame (debug paint all green,
// 62-70% of opaque HUD pixels restored), as the game's resources are not hazard tracked.
id<MTLTexture> g_uiSnap, g_uiSnapLow;
uint64_t g_uiSnapFrame = 0;
id<MTLTexture> g_hudOut; // the generated frame with the HUD restored
// METALFX_FG_HUDDEBUG=1 (or SetHudDebug): paint the restored area magenta, the rest green, on generated frames.
std::atomic<bool> g_hudDebug{[] {
    const char* env = std::getenv("METALFX_FG_HUDDEBUG");
    return env && *env == '1';
}()};
id<MTLTexture> Make(id<MTLDevice> d, MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage usage);
bool Fits(id<MTLTexture> t, id<MTLTexture> like);

bool HudPipelines(id<MTLDevice> dev)
{
    if (g_hud && g_uiCopy && g_uiCopyArray) {
        return true;
    }
    NSError* error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kHudSource options:nil error:&error];
    g_hud = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fg_hud"] error:&error];
    g_uiCopy = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fg_ui_copy"] error:&error];
    g_uiCopyArray = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fg_ui_copy_array"] error:&error];
    if (!g_hud || !g_uiCopy || !g_uiCopyArray) {
        Logger::Error(std::string("FrameGen: HUD kernels failed: ") +
                      (error ? error.localizedDescription.UTF8String : "no library"));
        g_hud = nil;
        return false;
    }
    return true;
}

// Puts the HUD of this frame's real image (cur) over the generated one (gen) where the UI layer snapshot has coverage.
void RestoreHud(id<MTLCommandBuffer> cb, id<MTLTexture> gen, id<MTLTexture> cur, id<MTLTexture> ui)
{
    if (!HudPipelines(cb.device)) {
        return;
    }
    MetalTrace::Internal internal;
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_hud];
    [ce setTexture:gen atIndex:0];
    [ce setTexture:cur atIndex:1];
    [ce setTexture:ui atIndex:2];
    [ce setTexture:g_uiSnapLow ? g_uiSnapLow : ui atIndex:3];
    const uint32_t params[2] = {g_hudDebug.load() ? 1u : 0u, g_uiSnapLow ? 1u : 0u};
    [ce setBytes:params length:sizeof(params) atIndex:0];
    [ce dispatchThreads:MTLSizeMake(gen.width, gen.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding];
    static std::atomic<int> logged{0};
    if (logged.fetch_add(1) < 2) {
        char buf[240];
        std::snprintf(buf, sizeof(buf), "FrameGen: HUD pass encoded (encoder %s, gen %lux%lu usage %lu, ui %lux%lu format %lu)",
                      class_getName([ce class]), (unsigned long)gen.width, (unsigned long)gen.height,
                      (unsigned long)gen.usage, (unsigned long)ui.width, (unsigned long)ui.height,
                      (unsigned long)ui.pixelFormat);
        Logger::Info(buf);
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
          Logger::Info(std::string("FrameGen: HUD pass command buffer status ") + std::to_string(done.status) +
                       (done.error ? std::string(" error ") + done.error.localizedDescription.UTF8String : ""));
        }];
    }
}

// The generated frame (g_out) with this frame's HUD over it, as a new texture: a copy of g_out first, because a compute
// pass on g_out itself right after the interpolator lost its writes in the game (MetalFX's output write landed after
// it), while copies of g_out encoded after the interpolator always see its output. g_out when there is no UI layer.
id<MTLTexture> WithHud(id<MTLCommandBuffer> cb, id<MTLTexture> gen, id<MTLTexture> cur, id<MTLTexture> ui)
{
    if (!ui || ui.width != gen.width || ui.height != gen.height) {
        return gen;
    }
    if (!Fits(g_hudOut, gen)) {
        g_hudOut = Make(gen.device, gen.pixelFormat, gen.width, gen.height,
                        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:gen toTexture:g_hudOut];
    [blit endEncoding];
    RestoreHud(cb, g_hudOut, cur, ui);
    return g_hudOut;
}

// The UI layer drawn for the frame being presented (most passes, if several); nil if none.
id<MTLTexture> CurrentUi(uint64_t frame)
{
    std::lock_guard<std::mutex> lock(g_uiMutex);
    id<MTLTexture> best = nil;
    unsigned passes = 0;
    if (g_uiLogged < 3) {
        ++g_uiLogged;
        for (auto& [ptr, u] : g_uiTargets) {
            if (u.texture.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB) {
                continue;
            }
            char buf[200];
            std::snprintf(buf, sizeof(buf), "FrameGen: UI layer %p format %lu last drawn in frame %llu (%u passes), now %llu",
                          ptr, (unsigned long)u.texture.pixelFormat, (unsigned long long)u.frame, u.passes,
                          (unsigned long long)frame);
            Logger::Info(buf);
        }
    }
    for (auto& [ptr, u] : g_uiTargets) {
        if (u.texture.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB && frame - u.frame <= 1 && u.passes > passes) {
            best = u.texture;
            passes = u.passes;
        }
    }
    return best;
}

const bool g_passJitter = [] {
    const char* env = std::getenv("METALFX_FG_JITTER");
    return !(env && *env == '0');
}();
uint64_t g_inputsFrame = 0, g_frame = 0; // the frame (present count) whose depth and motion are in g_depth/g_motion
float g_jitter[2] = {0, 0}, g_mvScale[2] = {1, 1};
bool g_reset = true, g_depthReversed = true;
double g_lastPresent = 0;
// Why presents went the usual way (logged every 240 presents while on): 0 framebuffer only, 1 no depth/motion for this
// frame, 2 first frame (no previous), 3 no extra drawable, 4 generated.
uint64_t g_why[5] = {};

void Count(int why)
{
    ++g_why[why];
    uint64_t total = 0;
    for (uint64_t x : g_why) {
        total += x;
    }
    if (total % 240 == 0) {
        char buf[200];
        std::snprintf(buf, sizeof(buf), "FrameGen: last 240 presents: %llu generated, %llu stale inputs, %llu no previous, "
                      "%llu no drawable, %llu framebuffer only", (unsigned long long)g_why[4],
                      (unsigned long long)g_why[1], (unsigned long long)g_why[2], (unsigned long long)g_why[3],
                      (unsigned long long)g_why[0]);
        Logger::Info(buf);
        std::fill(std::begin(g_why), std::end(g_why), 0);
    }
}
std::atomic<int> g_logged{0};

// Displayed frame intervals (presented handlers of the generated and the game's drawables), logged every 240.
std::mutex g_shownMutex;
std::vector<double> g_shown;

void NoteShown(id<MTLDrawable> d)
{
    [d addPresentedHandler:^(id<MTLDrawable> drawable) {
        const double t = drawable.presentedTime;
        if (t <= 0) {
            return; // not shown (dropped)
        }
        std::lock_guard<std::mutex> lock(g_shownMutex);
        g_shown.push_back(t);
        if (g_shown.size() < 241) {
            return;
        }
        std::sort(g_shown.begin(), g_shown.end());
        std::vector<double> dt;
        for (size_t i = 1; i < g_shown.size(); ++i) {
            dt.push_back((g_shown[i] - g_shown[i - 1]) * 1000.0);
        }
        std::sort(dt.begin(), dt.end());
        char buf[200];
        std::snprintf(buf, sizeof(buf), "FrameGen: displayed frame interval %.1f ms (%.0f fps; p95 %.1f ms) over %zu frames",
                      dt[dt.size() / 2], 1000.0 / dt[dt.size() / 2], dt[dt.size() * 95 / 100], dt.size());
        Logger::Info(buf);
        g_shown.clear();
    }];
}

id<MTLTexture> Make(id<MTLDevice> d, MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage usage)
{
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = usage;
    td.storageMode = MTLStorageModePrivate;
    return [d newTextureWithDescriptor:td];
}

bool Fits(id<MTLTexture> t, id<MTLTexture> like)
{
    return t && t.pixelFormat == like.pixelFormat && t.width == like.width && t.height == like.height;
}

} // namespace

namespace FrameGen {

void RenderPass(id desc)
{
    if (!Enabled() || !g_outW.load()) {
        return;
    }
    MTLRenderPassDescriptor* rp = desc;
    for (NSUInteger i = 0; i < 8; ++i) {
        id<MTLTexture> t = rp.colorAttachments[i].texture;
        if (t && (t.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB || t.pixelFormat == MTLPixelFormatRGBA16Float) &&
            t.width == g_outW.load() && t.height == g_outH.load() && !t.isFramebufferOnly &&
            ![t.label hasPrefix:@"CAMetalLayer"]) {
            std::lock_guard<std::mutex> lock(g_uiMutex);
            UiTarget& u = g_uiTargets[(__bridge void*)t];
            u.texture = t;
            if (u.frame != g_frame) {
                u.passes = 0;
            }
            u.frame = g_frame;
            ++u.passes;
        }
    }
}

void Evaluate(int samples)
{
    g_saveUi.store(true);
    g_uiLogged = 0;
    std::lock_guard<std::mutex> lock(g_mutex);
    g_evalLeft.store(std::max(0, samples));
    g_havePrev2 = false;
    g_evalWait = 0;
    g_evalNormal = 0;
    g_evalWarm = 0;
    g_evalInterp = nil;
    Logger::Info("FrameGen: evaluating " + std::to_string(samples) + " samples");
}

void HudComposite(id encoder)
{
    if (!Enabled()) {
        return;
    }
    uint64_t frame;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        frame = g_frame;
    }
    id<MTLTexture> ui = CurrentUi(frame);
    if (!ui) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!HudPipelines(ui.device)) {
        return;
    }
    if (!g_uiSnap || g_uiSnap.width != ui.width || g_uiSnap.height != ui.height) {
        g_uiSnap = Make(ui.device, MTLPixelFormatR8Unorm, ui.width, ui.height,
                        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        g_uiSnapLow = ui.mipmapLevelCount > 4 ? Make(ui.device, MTLPixelFormatR8Unorm, std::max<NSUInteger>(1, ui.width >> 4),
                                                     std::max<NSUInteger>(1, ui.height >> 4),
                                                     MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)
                                              : nil;
    }
    MetalTrace::Internal internal;
    id<MTLComputeCommandEncoder> ce = encoder; // the game's, still open: the copies run last in it
    [ce setComputePipelineState:ui.textureType == MTLTextureType2DArray ? g_uiCopyArray : g_uiCopy];
    [ce setTexture:ui atIndex:0];
    for (uint32_t lod : {0u, 4u}) {
        id<MTLTexture> dst = lod ? g_uiSnapLow : g_uiSnap;
        if (!dst) {
            continue;
        }
        [ce setTexture:dst atIndex:1];
        [ce setBytes:&lod length:sizeof(lod) atIndex:0];
        [ce dispatchThreads:MTLSizeMake(dst.width, dst.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    }
    g_uiSnapFrame = frame + 1; // for the frame being presented next
}

void SetHudDebug(bool on)
{
    g_hudDebug.store(on);
}

id LastGenerated()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_hudOut;
}

void SetEnabled(bool on)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_on.exchange(on) != on) {
        g_havePrev = false;
        g_reset = true;
        Logger::Info(std::string("FrameGen: ") + (on ? "on" : "off"));
    }
}

bool Enabled()
{
    return g_on.load(std::memory_order_relaxed);
}

std::atomic<unsigned long long> g_generated{0};

unsigned long long Generated()
{
    return g_generated.load();
}

void AfterScaler(id scaler, id commandBuffer)
{
    if (!Enabled()) {
        return;
    }
    id<MTLFXTemporalScaler> s = scaler;
    id<MTLTexture> depth = s.depthTexture, motion = s.motionTexture;
    if (!depth || !motion) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!Fits(g_depth, depth)) {
        g_depth = Make(depth.device, depth.pixelFormat, depth.width, depth.height,
                       MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    }
    if (!Fits(g_motion, motion)) {
        g_motion = Make(motion.device, motion.pixelFormat, motion.width, motion.height, MTLTextureUsageShaderRead);
    }
    id<MTLBlitCommandEncoder> blit = [(id<MTLCommandBuffer>)commandBuffer blitCommandEncoder];
    if (depth.textureType == MTLTextureType2D && motion.textureType == MTLTextureType2D) {
        [blit copyFromTexture:depth toTexture:g_depth];
        [blit copyFromTexture:motion toTexture:g_motion];
    } else { // the game's 2D arrays: slice 0
        for (auto [src, dst] : {std::pair{depth, g_depth}, std::pair{motion, g_motion}}) {
            [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(src.width, src.height, 1) toTexture:dst destinationSlice:0
                 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
    }
    [blit endEncoding];
    g_jitter[0] = s.jitterOffsetX;
    g_jitter[1] = s.jitterOffsetY;
    g_mvScale[0] = s.motionVectorScaleX;
    g_mvScale[1] = s.motionVectorScaleY;
    g_depthReversed = s.isDepthReversed;
    g_reset = g_reset || s.reset;
    g_inputsFrame = g_frame + 1; // for the frame being presented next
}

// The overlay layer frames are shown through while frame generation is on (see the header comment). Created and removed
// on the main thread; the render thread only uses it once it is set.
CAMetalLayer* g_overlay;
bool g_overlayPending = false;
int g_slowDrawables = 0; // consecutive overlay drawable waits over 50 ms (the safety valve)

void SetupOverlay(CAMetalLayer* game)
{
    auto make = ^{
        CAMetalLayer* o = [CAMetalLayer layer];
        o.device = game.device;
        o.pixelFormat = game.pixelFormat;
        o.colorspace = game.colorspace;
        o.wantsExtendedDynamicRangeContent = game.wantsExtendedDynamicRangeContent;
        o.EDRMetadata = game.EDRMetadata;
        o.framebufferOnly = NO;
        o.opaque = YES;
        o.contentsScale = game.contentsScale;
        o.drawableSize = game.drawableSize;
        o.frame = game.bounds;
        o.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        o.maximumDrawableCount = 3;
        o.displaySyncEnabled = YES;
        [game addSublayer:o];
        std::lock_guard<std::mutex> lock(g_mutex);
        g_overlay = o;
        g_overlayPending = false;
        Logger::Info("FrameGen: overlay layer ready");
    };
    if ([NSThread isMainThread]) {
        make();
    } else {
        dispatch_async(dispatch_get_main_queue(), make);
    }
}

void RemoveOverlay() // caller holds g_mutex
{
    if (!g_overlay) {
        return;
    }
    CAMetalLayer* o = g_overlay;
    g_overlay = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      [o removeFromSuperlayer];
    });
}

// A drawable of the overlay; counts slow waits and turns frame generation off after three in a row.
id<CAMetalDrawable> OverlayDrawable()
{
    const double t0 = CACurrentMediaTime();
    id<CAMetalDrawable> d = [g_overlay nextDrawable];
    const double waited = CACurrentMediaTime() - t0;
    g_slowDrawables = waited > 0.05 ? g_slowDrawables + 1 : 0;
    if (g_slowDrawables >= 3) {
        Logger::Error("FrameGen: waited " + std::to_string(static_cast<int>(waited * 1000)) +
                      " ms for a drawable three times in a row: frame generation off");
        g_on.store(false);
        g_slowDrawables = 0;
        RemoveOverlay();
    }
    return d;
}

bool Present(id commandBuffer, id drawable, const std::function<void(id)>& present,
             const std::function<void(id, double)>& presentAfter)
{
    id<CAMetalDrawable> d = drawable;
    CAMetalLayer* layer = d.layer;
    id<MTLTexture> tex = d.texture;
    static std::atomic<bool> firstLogged{false};
    if (!firstLogged.exchange(true)) {
        char buf[300];
        std::snprintf(buf, sizeof(buf),
                      "FrameGen: game presents %lux%lu format %lu usage %lu framebufferOnly %d, layer drawables %lu, "
                      "display sync %d, layer %.0fx%.0f",
                      (unsigned long)tex.width, (unsigned long)tex.height, (unsigned long)tex.pixelFormat,
                      (unsigned long)tex.usage, layer.framebufferOnly ? 1 : 0, (unsigned long)layer.maximumDrawableCount,
                      layer.displaySyncEnabled ? 1 : 0, layer.drawableSize.width, layer.drawableSize.height);
        Logger::Info(buf);
    }
    if (!Enabled() || !layer || !tex) {
        if (g_overlay) {
            std::lock_guard<std::mutex> lock(g_mutex);
            RemoveOverlay(); // the game's own presents show again
        }
        return false;
    }
    if (@available(macOS 26.0, *)) {
        std::unique_lock<std::mutex> lock(g_mutex);
        ++g_frame;
        if (layer.framebufferOnly) {
            layer.framebufferOnly = NO; // readable from the next drawable on
            g_havePrev = false;
            Count(0);
            return false;
        }
        if (!g_overlay) {
            if (!g_overlayPending) {
                g_overlayPending = true;
                lock.unlock();
                SetupOverlay(layer);
            }
            return false; // the game presents until the overlay is up
        }
        if (g_overlay.drawableSize.width != layer.drawableSize.width ||
            g_overlay.drawableSize.height != layer.drawableSize.height) {
            g_overlay.drawableSize = layer.drawableSize;
        }
        g_outW.store(tex.width);
        g_outH.store(tex.height);
        if (g_saveUi.exchange(false)) { // the UI layer candidates drawn in the last two frames, as PNGs
            std::lock_guard<std::mutex> uiLock(g_uiMutex);
            int i = 0;
            for (auto& [ptr, u] : g_uiTargets) {
                if (g_frame - u.frame <= 2) {
                    id<MTLTexture> t = u.texture;
                    char buf[160];
                    std::snprintf(buf, sizeof(buf), "FrameGen: UI candidate fgui%d %p, %u passes in frame %llu", i, ptr,
                                  u.passes, (unsigned long long)u.frame);
                    Logger::Info(buf);
                    MetalTrace::SaveTexture(commandBuffer, t, "fgui" + std::to_string(i++));
                }
            }
            MetalTrace::SaveTexture(commandBuffer, tex, "fgui-screen");
        }
        id<MTLDevice> dev = tex.device;
        const MTLTextureUsage colorUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                                           MTLTextureUsageRenderTarget;
        if (!Fits(g_cur, tex) || !Fits(g_prev, tex)) {
            g_cur = Make(dev, tex.pixelFormat, tex.width, tex.height, colorUsage);
            g_prev = Make(dev, tex.pixelFormat, tex.width, tex.height, colorUsage);
            g_out = Make(dev, tex.pixelFormat, tex.width, tex.height, colorUsage);
            g_havePrev = false;
            g_interp = nil;
        }
        id<MTLCommandBuffer> cb = commandBuffer;
        const double now = CACurrentMediaTime();
        const double dt = g_lastPresent > 0 ? std::min(0.1, now - g_lastPresent) : 1.0 / 30.0;
        g_lastPresent = now;
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:tex toTexture:g_cur];
        [blit endEncoding];

        // The game's frame through the overlay; its own drawable goes back to its pool unpresented.
        id<CAMetalDrawable> real = OverlayDrawable();
        if (!real || !g_on.load()) {
            std::swap(g_prev, g_cur);
            return false;
        }
        // A generated frame before it, when this frame has depth and motion and there is a previous frame.
        id<CAMetalDrawable> generated = nil;
        id<MTLTexture> genTex = g_out; // what the generated drawable shows (g_out, or a copy with the HUD restored)
        const bool fresh = g_inputsFrame == g_frame && g_depth;
        if (!fresh) {
            Count(1);
        } else if (!g_havePrev) {
            Count(2);
        } else if (g_evalLeft.load() > 0 && g_evalNormal >= 3 && g_havePrev2 && ++g_evalWait % 2 == 0 && g_interp) {
            // Quality check: N-2 to N with doubled motion, against the real N-1 (in g_prev); no generated frame shown.
            // A second interpolator sees only every other frame, so its previous color is always this call's N-2; its
            // first call resets it, and the first two calls are not saved (after a reset it returns its color input).
            const bool first = !g_evalInterp;
            if (first) {
                MTLFXFrameInterpolatorDescriptor* fd = [MTLFXFrameInterpolatorDescriptor new];
                fd.colorTextureFormat = tex.pixelFormat;
                fd.outputTextureFormat = tex.pixelFormat;
                fd.depthTextureFormat = g_depth.pixelFormat;
                fd.motionTextureFormat = g_motion.pixelFormat;
                fd.inputWidth = g_depth.width;
                fd.inputHeight = g_depth.height;
                fd.outputWidth = tex.width;
                fd.outputHeight = tex.height;
                g_evalInterp = [fd newFrameInterpolatorWithDevice:dev];
            }
            id<MTLFXFrameInterpolator> fi = g_evalInterp;
            const bool jitter = g_passJitter, useUi = g_useUi && g_evalIndex % 2 == 1;
            id<MTLTexture> ui = useUi && g_uiSnapFrame == g_frame ? g_uiSnap : nil;
            fi.colorTexture = g_cur;
            fi.prevColorTexture = g_prev2;
            fi.depthTexture = g_depth;
            fi.motionTexture = g_motion;
            fi.outputTexture = g_out;
            fi.motionVectorScaleX = 2 * g_mvScale[0];
            fi.motionVectorScaleY = 2 * g_mvScale[1];
            fi.jitterOffsetX = jitter ? g_jitter[0] : 0.0f;
            fi.jitterOffsetY = jitter ? g_jitter[1] : 0.0f;
            fi.deltaTime = static_cast<float>(2 * dt);
            float fov = 60.0f, nearPlane = 0.02f, aspect = static_cast<float>(tex.width) / tex.height;
            Denoise::Projection(fov, nearPlane, aspect);
            fi.nearPlane = nearPlane;
            fi.farPlane = 20000.0f;
            fi.fieldOfView = fov;
            fi.aspectRatio = aspect;
            fi.depthReversed = g_depthReversed;
            fi.shouldResetHistory = first;
            [fi encodeToCommandBuffer:cb];
            id<MTLTexture> shown = WithHud(cb, g_out, g_cur, ui);
            if (++g_evalWarm <= 2) {
                goto evalDone;
            }
            {
            const std::string base = "fgeval" + std::to_string(g_evalIndex);
            MetalTrace::SaveTexture(cb, shown, base + "-gen-u" + (ui ? "1" : "0"));
            if (ui) {
                MetalTrace::SaveTexture(cb, ui, base + "-ui");
            }
            MetalTrace::SaveTexture(cb, g_prev, base + "-real");
            MetalTrace::SaveTexture(cb, g_prev2, base + "-prev2");
            MetalTrace::SaveTexture(cb, g_cur, base + "-cur");
            ++g_evalIndex;
            if (g_evalLeft.fetch_sub(1) == 1) {
                Logger::Info("FrameGen: evaluation done");
                g_evalInterp = nil;
            }
            }
        evalDone:
            g_reset = true; // the game-rate interpolator skipped this frame: its history no longer matches g_prev
        } else {
            id<MTLFXFrameInterpolator> fi = g_interp;
            if (!fi || fi.inputWidth != g_depth.width || fi.inputHeight != g_depth.height ||
                fi.depthTextureFormat != g_depth.pixelFormat || fi.motionTextureFormat != g_motion.pixelFormat) {
                MTLFXFrameInterpolatorDescriptor* fd = [MTLFXFrameInterpolatorDescriptor new];
                fd.colorTextureFormat = tex.pixelFormat;
                fd.outputTextureFormat = tex.pixelFormat;
                fd.depthTextureFormat = g_depth.pixelFormat;
                fd.motionTextureFormat = g_motion.pixelFormat;
                fd.inputWidth = g_depth.width;
                fd.inputHeight = g_depth.height;
                fd.outputWidth = tex.width;
                fd.outputHeight = tex.height;
                fi = [fd newFrameInterpolatorWithDevice:dev];
                g_interp = fi;
                char buf[200];
                std::snprintf(buf, sizeof(buf), "FrameGen: interpolator %lux%lu -> %lux%lu (color %lu) %s",
                              (unsigned long)g_depth.width, (unsigned long)g_depth.height, (unsigned long)tex.width,
                              (unsigned long)tex.height, (unsigned long)tex.pixelFormat, fi ? "ready" : "unavailable");
                Logger::Info(buf);
            }
            generated = fi ? OverlayDrawable() : nil;
            if (!generated) {
                Count(3);
            } else {
                fi.colorTexture = g_cur;
                fi.prevColorTexture = g_prev;
                fi.depthTexture = g_depth;
                fi.motionTexture = g_motion;
                fi.outputTexture = g_out;
                fi.motionVectorScaleX = g_mvScale[0];
                fi.motionVectorScaleY = g_mvScale[1];
                fi.jitterOffsetX = g_passJitter ? g_jitter[0] : 0.0f;
                fi.jitterOffsetY = g_passJitter ? g_jitter[1] : 0.0f;
                fi.deltaTime = static_cast<float>(dt);
                float fov = 60.0f, nearPlane = 0.02f, aspect = static_cast<float>(tex.width) / tex.height;
                Denoise::Projection(fov, nearPlane, aspect);
                fi.nearPlane = nearPlane;
                fi.farPlane = 20000.0f;
                fi.fieldOfView = fov;
                fi.aspectRatio = aspect;
                fi.depthReversed = g_depthReversed;
                const bool wasReset = g_reset;
                fi.shouldResetHistory = g_reset;
                g_reset = false;
                [fi encodeToCommandBuffer:cb];
                genTex = WithHud(cb, g_out, g_cur, g_useUi && g_uiSnapFrame == g_frame ? g_uiSnap : nil);
                if (g_evalLeft.load() > 0 && g_evalNormal < 3 && !wasReset) { // what the game-rate path generates
                    const std::string base = "fgnormal" + std::to_string(g_evalNormal++);
                    MetalTrace::SaveTexture(cb, genTex, base + "-gen");
                    MetalTrace::SaveTexture(cb, g_prev, base + "-prev");
                    MetalTrace::SaveTexture(cb, g_cur, base + "-cur");
                }
                Count(4);
                g_generated.fetch_add(1);
            }
        }
        blit = [cb blitCommandEncoder];
        if (generated) {
            [blit copyFromTexture:genTex toTexture:generated.texture];
        }
        [blit copyFromTexture:g_cur toTexture:real.texture];
        [blit endEncoding];
        if (g_evalLeft.load() > 0) { // keep N-1 as the next frame's N-2
            if (!Fits(g_prev2, tex)) {
                g_prev2 = Make(dev, tex.pixelFormat, tex.width, tex.height, colorUsage);
            }
            id<MTLBlitCommandEncoder> keep = [cb blitCommandEncoder];
            [keep copyFromTexture:g_prev toTexture:g_prev2];
            [keep endEncoding];
            g_havePrev2 = g_havePrev && fresh;
        }
        std::swap(g_prev, g_cur);
        g_havePrev = fresh;
        if (!fresh) {
            g_reset = true;
        }
        lock.unlock();
        if (generated) {
            NoteShown(generated);
            NoteShown(real);
            present(generated);         // between the previous frame and this one
            presentAfter(real, dt / 2); // this frame half a frame interval later
        } else {
            present(real);
        }
        return true;
    }
    return false;
}

} // namespace FrameGen
