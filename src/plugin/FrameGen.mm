// MetalFX frame interpolation: one generated frame between every two frames the game presents. Built with ARC.
//
// Per real frame N:
// - At the game's MetalFX temporal scaler call (AfterScaler): copy the frame's depth and motion (render resolution)
//   into our own textures, so the next frame cannot overwrite them before the interpolation reads them.
// - At present (Present, on the game's last command buffer): copy the presented image into our history, run
//   MTLFXFrameInterpolator on frames N-1 and N (color: the presented images, post-processing and HUD included; depth and
//   motion: frame N's), write the result into a second drawable, present that, then present frame N at least half a
//   frame interval later (presentDrawable:afterMinimumDuration:). The generated frame is shown between N-1 and N; frame
//   N is shown half a frame later than it would be.
// - The presented images must be readable: the layer's framebufferOnly is turned off at the first present (from the
//   next drawable on).
// Camera: near plane, vertical field of view and aspect ratio from NRD's constants (Denoise::Projection; the game renders
// reversed-Z with an infinite far plane, given here as a large finite one).
//
// ponytail: the HUD is interpolated with the scene (the game draws it into the same image and gives no separate UI
// texture); add a UI texture if HUD warping during camera motion is objectionable.

#include "FrameGen.hpp"
#include "Denoise.hpp"
#include "Logger.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>

#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

namespace {

std::atomic<bool> g_on{false};
std::mutex g_mutex;

id g_interp; // id<MTLFXFrameInterpolator>
id<MTLTexture> g_prev, g_cur, g_out, g_depth, g_motion;
bool g_havePrev = false;
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
        if (g_inputsFrame != g_frame || !g_depth) {
            g_havePrev = false; // no MetalFX call this frame (menus, loading): nothing to interpolate with
            Count(1);
            return false;
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
            g_havePrev = false;
            char buf[200];
            std::snprintf(buf, sizeof(buf), "FrameGen: interpolator %lux%lu -> %lux%lu (color %lu) %s",
                          (unsigned long)g_depth.width, (unsigned long)g_depth.height, (unsigned long)tex.width,
                          (unsigned long)tex.height, (unsigned long)tex.pixelFormat, fi ? "ready" : "unavailable");
            Logger::Info(buf);
            if (!fi) {
                g_on.store(false);
                return false;
            }
        }
        id<MTLCommandBuffer> cb = commandBuffer;
        const double now = CACurrentMediaTime();
        const double dt = g_lastPresent > 0 ? std::min(0.1, now - g_lastPresent) : 1.0 / 30.0;
        g_lastPresent = now;
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:tex toTexture:g_cur];
        [blit endEncoding];
        if (!g_havePrev) {
            std::swap(g_prev, g_cur);
            g_havePrev = true;
            g_reset = true;
            Count(2);
            return false;
        }
        id<CAMetalDrawable> extra = [layer nextDrawable];
        if (!extra) {
            std::swap(g_prev, g_cur);
            Count(3);
            return false;
        }
        fi.colorTexture = g_cur;
        fi.prevColorTexture = g_prev;
        fi.depthTexture = g_depth;
        fi.motionTexture = g_motion;
        // Straight into the extra drawable when it allows it (saves a full-size copy), else via g_out.
        id<MTLTexture> target = extra.texture;
        const bool direct = (target.usage & fi.outputTextureUsage) == fi.outputTextureUsage &&
                            target.storageMode == MTLStorageModePrivate;
        static std::atomic<bool> usageLogged{false};
        if (!usageLogged.exchange(true)) {
            Logger::Info("FrameGen: drawable usage " + std::to_string(target.usage) + ", interpolator output needs " +
                         std::to_string(fi.outputTextureUsage) + (direct ? ": writing into the drawable" :
                                                                           ": writing through a copy"));
        }
        fi.outputTexture = direct ? target : g_out;
        fi.motionVectorScaleX = g_mvScale[0];
        fi.motionVectorScaleY = g_mvScale[1];
        fi.jitterOffsetX = g_jitter[0];
        fi.jitterOffsetY = g_jitter[1];
        fi.deltaTime = static_cast<float>(dt);
        float fov = 60.0f, nearPlane = 0.02f, aspect = static_cast<float>(tex.width) / tex.height;
        Denoise::Projection(fov, nearPlane, aspect);
        fi.nearPlane = nearPlane;
        fi.farPlane = 20000.0f;
        fi.fieldOfView = fov;
        fi.aspectRatio = aspect;
        fi.depthReversed = g_depthReversed;
        fi.shouldResetHistory = g_reset;
        g_reset = false;
        [fi encodeToCommandBuffer:cb];
        if (!direct) {
            blit = [cb blitCommandEncoder];
            [blit copyFromTexture:g_out toTexture:target];
            [blit endEncoding];
        }
        std::swap(g_prev, g_cur);
        Count(4);
        g_generated.fetch_add(1);
        lock.unlock();
        NoteShown(extra);
        NoteShown(d);
        present(extra);              // the generated frame, between N-1 and N
        presentAfter(drawable, dt / 2); // frame N half a frame interval later
        if (g_logged.load() < 3) {
            g_logged.fetch_add(1);
            Logger::Info("FrameGen: presenting generated frames");
        }
        return true;
    }
    return false;
}

} // namespace FrameGen
