// Ray traced denoiser: NRD RELAX pass-through plus MetalFX's temporal denoised scaler. Built with ARC.
//
// Modes (config.toml [denoiser] mode, environment METALFX_DENOISE, or the tracer request "denoise off|pass|fx"):
// - pass: RELAX's dispatches are dropped and its noisy (or checkerboard-resolved) inputs are copied to its outputs, so
//   the game composites noisy lighting. The game's MetalFX temporal scaler still runs.
// - fx: pass, plus the game's MetalFX temporal scaler call is replaced by MTLFXTemporalDenoisedScaler (macOS 26), fed
//   guide textures made from the G-buffer and the camera matrices from NRD's constants.
//
// RELAX chains (PIPELINE_TRACE_FINDINGS.md; labels are the engine's compute pipeline labels, stable across runs;
// nothing happens where they are not seen, so raster frames are untouched):
// - Path tracing, one serial encoder, two instances: HitDistReconstruction (2684890295, first instance only) or PrePass
//   (1624964913) reads the two noisy RGBA16Float radiance textures (diffuse, specular); four a-trous iterations
//   (1807644384) follow, the last writing both outputs. By default the passes up to PrePass keep running and PrePass's
//   two outputs are copied (see g_ptPrepass); otherwise everything is dropped and the noisy inputs are copied.
// - RT Ultra/Psycho, one encoder each for diffuse and specular: the PrePass (2146613912 diffuse, 2571244900 specular)
//   resolves the half width checkerboard into one RGBA16Float texture and keeps running; everything after it up to the
//   last a-trous iteration (1741889550 diffuse, 3863891985 specular), which writes the output, is dropped.
// The copies are encoded into the same encoder just before it ends, after a texture barrier.
//
// G-buffer: render passes with BGR10A2Unorm, BGR10A2Unorm, RGBA8Unorm targets hold base color, world-space normal
// (xyz * 0.5 + 0.5) and metalness (R) / roughness (G). The guide textures are written from them once per frame in a
// RELAX encoder, where the G-buffer is certainly alive.
//
// Camera: NRD's constant buffer (RELAX shared constants: gWorldToClipPrev, gWorldToViewPrev, gWorldToClip at +128,
// gWorldPrevToWorld, gViewToWorld at +256, frustum vectors, gCameraDelta at +416, ..., the resource size at +496; HLSL
// column-major, so each float4 is a column, as in simd_float4x4). It is found at the chain's first dispatch through
// Metal Shader Converter's root arguments: the top-level argument buffer (index 2) holds descriptor table addresses;
// each 24-byte descriptor starts with a buffer address; the constant buffer is the one whose resource size matches the
// noisy texture and whose gViewToWorld is a rotation (the engine renders camera-relative, so it has no translation).
// The buffers are read through MetalTrace's registry of the game's large shared heap buffers.

#include "Denoise.hpp"
#include "Logger.hpp"
#include "MetalTrace.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {

enum Mode { Off, Pass, Fx };
std::atomic<int> g_mode{Off};
std::atomic<bool> g_watch{false}; // read the camera even when off (motion tests)
enum CamMode { CamGame, CamIdentity, CamRightHanded };
std::atomic<int> g_camMode{CamGame};

struct Chain {
    const char* name;
    const char* start[2];
    const char* keep; // this pass (and those before it) keep running; its RGBA16Float output is the copy source
    const char* end;
    size_t width;     // textures per instance
    bool reverse;     // the copy sources' address order is the reverse of the outputs' (see kChains)
};
// Path tracing keeps its PrePass when g_ptPrepass is set (the default): its light spatial pre-blur fills the
// disoccluded bands at the screen edges that fast camera turns at low frame rates uncover, which the raw signal
// shows nearly black until the denoiser's history builds up.
std::atomic<bool> g_ptPrepass{true};
const Chain kChains[] = {
    {"path tracing", {"2684890295", "1624964913"}, nullptr, "1807644384", 2, false},
    // The path tracing PrePass's two outputs are allocated specular first: paired by address order, diffuse and
    // specular swapped and washed out the colors (skin turned pale white). Reversed, the image is the closest to the
    // game's NRD of all variants (skin scenario at Kabuki Market: mean error 4.8 against 14.2 swapped, 5.1 raw).
    {"path tracing", {"2684890295", "1624964913"}, "1624964913", "1807644384", 2, true},
    {"diffuse", {"2146613912", nullptr}, "2146613912", "1741889550", 1, false},
    {"specular", {"2571244900", nullptr}, "2571244900", "3863891985", 1, false},
};

const Chain* StartOf(const std::string& label)
{
    for (const Chain& c : kChains) {
        if (&c == &kChains[0] ? g_ptPrepass.load() : &c == &kChains[1] ? !g_ptPrepass.load() : false) {
            continue;
        }
        for (const char* s : c.start) {
            if (s && label == s) {
                return &c;
            }
        }
    }
    return nullptr;
}

struct Job {
    id<MTLTexture> in, out;
};

struct Enc {
    std::string label;
    std::vector<std::pair<__unsafe_unretained id, unsigned long>> uses;
    __unsafe_unretained id root = nil; // the top-level argument buffer (index 2), alive while bound
    unsigned long rootOffset = 0;
    const Chain* chain = nullptr;
    bool open = false;
    int atrous = 0;
    bool kept = false; // the chain's keep pass has run
    std::vector<id<MTLTexture>> in, out;
    std::vector<Job> jobs;
};

std::mutex g_mutex;
std::unordered_map<const void*, Enc> g_enc;
std::atomic<bool> g_hudFxOff{false}; // SetHudEffectsOff (HudConstants)
id<MTLTexture> g_gbuf[3];
std::atomic<int> g_logged{0};
bool g_failed = false; // fx: setup failed, the game's scaler runs

// Frame bookkeeping, in scaler calls (one per frame): the frame the last copies and guides were encoded in.
std::atomic<uint64_t> g_frame{0}, g_passFrame{~0ull}, g_guideFrame{~0ull};
// When the game last called its MetalFX temporal scaler. fx passes RELAX through only while it does (another
// upscaler, FSR, would otherwise show the noisy lighting).
std::atomic<int64_t> g_scalerMs{-1000000};

int64_t NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

struct Camera {
    simd_float4x4 worldToClip, viewToWorld;
    float delta[4];
    uint64_t serial = 0;
};
Camera g_cam; // guarded by g_mutex
std::atomic<bool> g_camLogged{false};

id<MTLComputePipelineState> g_copy, g_guides, g_rcas, g_rcasArray;
id<MTLTexture> g_sharpSrc; // the scaler's output, copied for RCAS to read
std::atomic<float> g_sharpness{0.0f};
id<MTLTexture> g_diffuse, g_specular, g_normal, g_roughness; // guide textures, input size
id g_scaler;                                                  // id<MTLFXTemporalDenoisedScaler>

NSString* const kSource = @R"(
#include <metal_stdlib>
using namespace metal;

kernel void mfxd_copy(texture2d_array<half, access::read> a [[texture(0)]],
                      texture2d_array<half, access::write> b [[texture(1)]],
                      uint2 p [[thread_position_in_grid]])
{
    if (p.x >= b.get_width() || p.y >= b.get_height()) return;
    b.write(a.read(p, 0), p, 0);
}

kernel void mfxd_guides(texture2d_array<float, access::read> base [[texture(0)]],
                        texture2d_array<float, access::read> nrm [[texture(1)]],
                        texture2d_array<float, access::read> mat [[texture(2)]],
                        texture2d<float, access::write> diffuse [[texture(3)]],
                        texture2d<float, access::write> specular [[texture(4)]],
                        texture2d<float, access::write> normal [[texture(5)]],
                        texture2d<float, access::write> roughness [[texture(6)]],
                        uint2 p [[thread_position_in_grid]])
{
    if (p.x >= diffuse.get_width() || p.y >= diffuse.get_height()) return;
    const float3 c = base.read(p, 0).rgb;
    const float4 m = mat.read(p, 0);
    diffuse.write(float4(c * (1.0 - m.r), 1.0), p);
    specular.write(float4(mix(float3(0.04), c, m.r), 1.0), p);
    normal.write(float4(normalize(nrm.read(p, 0).xyz * 2.0 - 1.0), 0.0), p);
    roughness.write(float4(m.g), p);
}

// RCAS (AMD FidelityFX FSR 1's robust contrast adaptive sharpening) on the upscaled HDR color, in a reversible tone
// mapped space (c / (1 + max(c))) so its [0, 1] limits hold: a 5-tap cross whose negative lobe is limited so that no
// channel leaves the range of its neighbours (no ringing, no halos).
inline float3 mfxd_tm(float3 c) { return c / (1.0 + max(max(c.r, c.g), max(c.b, 0.0))); }
inline float3 mfxd_itm(float3 t) { return t / max(1.0 - max(max(t.r, t.g), t.b), 1.0 / 65504.0); }

inline float4 mfxd_rcas_color(texture2d<float, access::read> src, float amount, uint2 p)
{
    const int2 s = int2(src.get_width(), src.get_height()) - 1, q = int2(p);
    auto at = [&](int2 o) { return mfxd_tm(src.read(uint2(clamp(q + o, int2(0), s))).rgb); };
    const float4 c = src.read(p);
    const float3 e = mfxd_tm(c.rgb), b = at(int2(0, -1)), d = at(int2(-1, 0)), f = at(int2(1, 0)), h = at(int2(0, 1));
    const float3 mn4 = min(min(b, d), min(f, h)), mx4 = max(max(b, d), max(f, h));
    const float3 hitMin = min(mn4, e) / (4.0 * mx4 + 1e-6);
    const float3 hitMax = (1.0 - max(mx4, e)) / (4.0 * mn4 - 4.0 - 1e-6);
    const float3 lobeRGB = max(-hitMin, hitMax);
    const float lobe = max(-0.1875, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * amount;
    const float3 o = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);
    return float4(mfxd_itm(saturate(o)), c.a);
}

kernel void mfxd_rcas(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float& amount [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    dst.write(mfxd_rcas_color(src, amount, p), p);
}

kernel void mfxd_rcas_array(texture2d<float, access::read> src [[texture(0)]],
                            texture2d_array<float, access::write> dst [[texture(1)]],
                            constant float& amount [[buffer(0)]], uint2 p [[thread_position_in_grid]])
{
    if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
    dst.write(mfxd_rcas_color(src, amount, p), p, 0);
}
)";

bool MakePipelines(id<MTLDevice> device)
{
    if (g_copy) {
        return true;
    }
    NSError* error = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kSource options:nil error:&error];
    id<MTLFunction> copy = [lib newFunctionWithName:@"mfxd_copy"], guides = [lib newFunctionWithName:@"mfxd_guides"];
    if (copy && guides) {
        g_copy = [device newComputePipelineStateWithFunction:copy error:&error];
        g_guides = [device newComputePipelineStateWithFunction:guides error:&error];
        g_rcas = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mfxd_rcas"] error:&error];
        g_rcasArray = [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"mfxd_rcas_array"]
                                                            error:&error];
    }
    if (!g_copy || !g_guides || !g_rcas || !g_rcasArray) {
        Logger::Error(std::string("Denoise: kernels failed: ") +
                      (error ? error.localizedDescription.UTF8String : "no library"));
        g_copy = nil;
        return false;
    }
    return true;
}

// The RGBA16Float textures among an encoder's declarations, read-only or written, ordered by address.
std::vector<id<MTLTexture>> Pick(const Enc& e, bool written)
{
    std::vector<id<MTLTexture>> out;
    for (const auto& [r, usage] : e.uses) {
        id<MTLTexture> t = (id<MTLTexture>)r;
        if (t.pixelFormat == MTLPixelFormatRGBA16Float && ((usage & MTLResourceUsageWrite) != 0) == written &&
            std::find(out.begin(), out.end(), t) == out.end()) {
            out.push_back(t);
        }
    }
    std::sort(out.begin(), out.end(), [](id a, id b) { return (__bridge void*)a < (__bridge void*)b; });
    return out;
}

void Close(Enc& e)
{
    if (e.chain->reverse && e.kept) {
        std::reverse(e.in.begin(), e.in.end());
    }
    if (e.in.size() == e.chain->width && e.out.size() == e.chain->width) {
        for (size_t i = 0; i < e.in.size(); ++i) {
            e.jobs.push_back({e.in[i], e.out[i]});
        }
    } else if (g_logged.fetch_add(1) < 4) {
        Logger::Warn(std::string("Denoise: RELAX ") + e.chain->name + " with " + std::to_string(e.in.size()) +
                     " inputs and " + std::to_string(e.out.size()) + " outputs; not copied");
    }
    e.open = false;
    e.atrous = 0;
    e.kept = false;
    e.in.clear();
    e.out.clear();
}

bool Array(id<MTLTexture> t)
{
    return t.textureType == MTLTextureType2DArray;
}

uint64_t U64(const uint8_t* p)
{
    uint64_t v;
    std::memcpy(&v, p, 8);
    return v;
}

bool IsRotation(const float* m) // column-major 4x4: three unit columns, no translation
{
    for (int c = 0; c < 3; ++c) {
        const float l = m[c * 4] * m[c * 4] + m[c * 4 + 1] * m[c * 4 + 1] + m[c * 4 + 2] * m[c * 4 + 2];
        if (std::fabs(l - 1.0f) > 1e-3f || m[c * 4 + 3] != 0.0f) {
            return false;
        }
    }
    return std::fabs(m[15] - 1.0f) < 1e-6f;
}

// Caller holds g_mutex. Finds NRD's constant buffer through the root arguments of a RELAX dispatch (see the header).
void ReadCamera(const Enc& e)
{
    id<MTLBuffer> root = e.root;
    float w = 0, h = 0;
    for (const auto& [r, usage] : e.uses) {
        id<MTLTexture> t = (id<MTLTexture>)r;
        if (t.pixelFormat == MTLPixelFormatRGBA16Float) {
            w = t.width;
            h = t.height;
            break;
        }
    }
    if (!root || root.storageMode == MTLStorageModePrivate || e.rootOffset + 128 > root.length || !w) {
        return;
    }
    const uint8_t* args = static_cast<const uint8_t*>(root.contents) + e.rootOffset;
    for (int i = 0; i < 16; ++i) {
        const uint8_t* table = MetalTrace::MapGpuAddress(U64(args + 8 * i), 24 * 16);
        for (int j = 0; table && j < 16; ++j) {
            const uint8_t* cb = MetalTrace::MapGpuAddress(U64(table + 24 * j), 512);
            if (!cb) {
                continue;
            }
            float f[128];
            std::memcpy(f, cb, sizeof(f));
            if (f[124] != w || f[125] != h || !IsRotation(f + 64)) {
                continue;
            }
            std::memcpy(&g_cam.worldToClip, f + 32, 64);
            std::memcpy(&g_cam.viewToWorld, f + 64, 64);
            std::memcpy(g_cam.delta, f + 104, 16);
            ++g_cam.serial;
            if (!g_camLogged.exchange(true)) {
                char buf[200];
                std::snprintf(buf, sizeof(buf), "Denoise: camera from NRD constants (root entry %d, descriptor %d); "
                              "forward %.3f %.3f %.3f", i, j, f[64 + 8], f[64 + 9], f[64 + 10]);
                Logger::Info(buf);
            }
            return;
        }
    }
}

// fx: guide textures at the G-buffer's size, written from it.
void EncodeGuides(id<MTLComputeCommandEncoder> ce)
{
    id<MTLTexture> gb[3];
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::copy(g_gbuf, g_gbuf + 3, gb);
    }
    if (!gb[0] || !Array(gb[0]) || !Array(gb[1]) || !Array(gb[2])) {
        return;
    }
    const NSUInteger w = gb[0].width, h = gb[0].height;
    if (!g_diffuse || g_diffuse.width != w || g_diffuse.height != h) {
        auto make = [&](MTLPixelFormat f) {
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h
                                                                                     mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            d.storageMode = MTLStorageModePrivate;
            return [ce.device newTextureWithDescriptor:d];
        };
        g_diffuse = make(MTLPixelFormatRGBA8Unorm);
        g_specular = make(MTLPixelFormatRGBA8Unorm);
        g_normal = make(MTLPixelFormatRGBA16Float);
        g_roughness = make(MTLPixelFormatR16Float);
    }
    [ce setComputePipelineState:g_guides];
    id<MTLTexture> ts[7] = {gb[0], gb[1], gb[2], g_diffuse, g_specular, g_normal, g_roughness};
    for (NSUInteger i = 0; i < 7; ++i) {
        [ce setTexture:ts[i] atIndex:i];
    }
    [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
}

} // namespace

namespace Denoise {

bool Supported()
{
    if (@available(macOS 26.0, *)) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device && [MTLFXTemporalDenoisedScalerDescriptor supportsDevice:device];
    }
    return false;
}

bool SetMode(const std::string& mode)
{
    const int m = mode == "off" ? Off : mode == "pass" ? Pass : mode == "fx" ? Fx : -1;
    if (m < 0) {
        return false;
    }
    g_mode.store(m);
    g_logged.store(0);
    Logger::Info("Denoise: mode " + mode);
    return true;
}

bool SetPrepass(bool on)
{
    g_ptPrepass.store(on);
    Logger::Info(std::string("Denoise: path tracing PrePass ") + (on ? "kept" : "dropped"));
    return true;
}

bool SetCameraMode(const std::string& mode)
{
    const int m = mode == "game" ? CamGame : mode == "identity" ? CamIdentity : mode == "rh" ? CamRightHanded : -1;
    if (m < 0) {
        return false;
    }
    g_camMode.store(m);
    Logger::Info("Denoise: camera matrices " + mode);
    return true;
}

void SetWatch(bool on)
{
    g_watch.store(on);
}

void SetHudEffectsOff(bool off)
{
    if (g_hudFxOff.exchange(off) != off) {
        Logger::Info(std::string("Denoise: game HUD effects ") + (off ? "off (plugin)" : "as the game sets them"));
    }
}

bool Active()
{
    return g_mode.load(std::memory_order_relaxed) != Off || g_watch.load(std::memory_order_relaxed);
}

bool Projection(float& fovY, float& nearPlane, float& aspect)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_cam.serial) {
        return false;
    }
    const simd_float4x4 p = simd_mul(g_cam.worldToClip, g_cam.viewToWorld); // view to clip
    if (p.columns[1][1] <= 0 || p.columns[0][0] <= 0) {
        return false;
    }
    fovY = 2.0f * std::atan(1.0f / p.columns[1][1]) * 57.29578f;
    aspect = p.columns[1][1] / p.columns[0][0];
    nearPlane = p.columns[3][2]; // reversed-Z, infinite far plane: clip z = near
    return nearPlane > 0;
}

bool Camera(float delta[4], float viewToWorld[16], uint64_t& serial)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_cam.serial) {
        return false;
    }
    std::memcpy(delta, g_cam.delta, 16);
    std::memcpy(viewToWorld, &g_cam.viewToWorld, 64);
    serial = g_cam.serial;
    return true;
}

void BindPipeline(id encoder, const std::string& label)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_enc[(__bridge const void*)encoder].label = label;
}

void SetRoot(id encoder, id buffer, unsigned long offset, bool offsetOnly)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    Enc& e = g_enc[(__bridge const void*)encoder];
    if (!offsetOnly) {
        e.root = buffer;
    }
    e.rootOffset = offset;
}

void Use(id encoder, const void* const* resources, size_t count, unsigned long usage)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    Enc& e = g_enc[(__bridge const void*)encoder]; // declarations can come before the first pipeline bind
    for (size_t i = 0; i < count; ++i) {
        id r = (__bridge id)resources[i];
        if ([r conformsToProtocol:@protocol(MTLTexture)]) {
            e.uses.emplace_back(r, usage);
        }
    }
}

// The game's HUD composite (m_hud_occupiedTiles, label 3959251910) reads its settings from a constant buffer: the
// first descriptor table of its top-level argument buffer, descriptor 6 (24-byte descriptors, buffer address first).
// Floats at byte 16 (the switch of the chromatic aberration and blurred echo copies of the HUD, along the radial
// vector from the screen centre), 48 and 52 (the HUD's barrel distortion), 108 (aberration strength), 112-140 (echo
// offsets). Logged every 600 calls; with SetHudEffectsOff, the switch and the distortion are zeroed before the GPU
// reads them, so the HUD is composited where the UI layer has it, without copies.

void HudConstants(const Enc& e) // caller holds g_mutex
{
    static std::atomic<unsigned> calls{0};
    static std::atomic<bool> failLogged{false};
    const unsigned n = calls.fetch_add(1);
    id<MTLBuffer> root = e.root;
    float* f = nullptr;
    if (root && root.storageMode != MTLStorageModePrivate && e.rootOffset + 8 <= root.length) {
        const uint8_t* args = static_cast<const uint8_t*>(root.contents) + e.rootOffset;
        if (const uint8_t* table = MetalTrace::MapGpuAddress(U64(args), 24 * 7)) {
            f = const_cast<float*>(reinterpret_cast<const float*>(MetalTrace::MapGpuAddress(U64(table + 24 * 6), 160)));
        }
    }
    if (!f) {
        if (!failLogged.exchange(true)) {
            Logger::Warn("Denoise: HUD composite constants not readable (root argument buffer or constant buffer not "
                         "in a shared buffer)");
        }
        return;
    }
    if (n % 600 == 0) {
        char buf[300];
        std::snprintf(buf, sizeof(buf),
                      "Denoise: HUD composite constants: effects switch %.3f, distortion %.4f %.4f, aberration %.4f, "
                      "echo offsets %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f%s",
                      f[4], f[12], f[13], f[27], f[28], f[29], f[30], f[31], f[32], f[33], f[34], f[35],
                      g_hudFxOff.load() ? " (plugin zeroes switch and distortion)" : "");
        Logger::Info(buf);
    }
    if (g_hudFxOff.load()) {
        f[4] = 0.0f;
        f[12] = 0.0f;
        f[13] = 0.0f;
    }
}

bool Dispatch(id encoder)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_enc.find((__bridge const void*)encoder);
    if (it == g_enc.end()) {
        return false;
    }
    Enc& e = it->second;
    bool drop = false;
    if (e.label == "3959251910") {
        HudConstants(e);
    }
    const Chain* c = StartOf(e.label);
    if (c && (!e.open || e.atrous > 0 || e.chain != c)) {
        if (e.open) {
            Close(e);
        }
        ReadCamera(e);
        const int mode = g_mode.load();
        if (mode == Pass || (mode == Fx && !g_failed && NowMs() - g_scalerMs.load() < 250)) {
            e.open = true;
            e.chain = c;
            if (!c->keep) {
                e.in = Pick(e, false); // the noisy inputs
                drop = true;
            } else if (e.label == c->keep) {
                e.in = Pick(e, true); // the keep pass's output
                e.kept = true;
            }
        }
    } else if (e.open && e.chain->keep && !e.kept) {
        if (e.label == e.chain->keep) {
            e.in = Pick(e, true);
            e.kept = true;
        }
    } else if (e.open && e.label == e.chain->end) {
        ++e.atrous;
        e.out = Pick(e, true);
        drop = true;
    } else if (e.open && e.atrous > 0) {
        Close(e);
    } else {
        drop = e.open;
    }
    e.uses.clear();
    return drop;
}

void EndEncoding(id encoder)
{
    std::vector<Job> jobs;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_enc.find((__bridge const void*)encoder);
        if (it == g_enc.end()) {
            return;
        }
        if (it->second.open) {
            Close(it->second);
        }
        jobs = std::move(it->second.jobs);
        g_enc.erase(it);
    }
    if (jobs.empty()) {
        return;
    }
    id<MTLComputeCommandEncoder> ce = encoder;
    if (!MakePipelines(ce.device)) {
        return;
    }
    [ce memoryBarrierWithScope:MTLBarrierScopeTextures];
    [ce setComputePipelineState:g_copy];
    for (const Job& j : jobs) {
        if (!Array(j.in) || !Array(j.out)) {
            continue;
        }
        [ce setTexture:j.in atIndex:0];
        [ce setTexture:j.out atIndex:1];
        [ce dispatchThreads:MTLSizeMake(j.out.width, j.out.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    }
    const uint64_t frame = g_frame.load();
    g_passFrame.store(frame);
    if (g_mode.load() == Fx && g_guideFrame.exchange(frame) != frame) {
        EncodeGuides(ce);
    }
    if (g_logged.fetch_add(1) == 0) {
        char buf[200];
        std::snprintf(buf, sizeof(buf), "Denoise: RELAX pass-through, %zu textures copied (%lux%lu)", jobs.size(),
                      (unsigned long)jobs[0].out.width, (unsigned long)jobs[0].out.height);
        Logger::Info(buf);
    }
    std::lock_guard<std::mutex> lock(g_mutex); // our own binds and dispatches re-created the entry
    g_enc.erase((__bridge const void*)encoder);
}

void RenderPass(id desc)
{
    if (g_mode.load(std::memory_order_relaxed) != Fx) {
        return;
    }
    MTLRenderPassDescriptor* rp = desc;
    id<MTLTexture> t[3] = {rp.colorAttachments[0].texture, rp.colorAttachments[1].texture,
                           rp.colorAttachments[2].texture};
    if (t[0].pixelFormat == MTLPixelFormatBGR10A2Unorm && t[1].pixelFormat == MTLPixelFormatBGR10A2Unorm &&
        t[2].pixelFormat == MTLPixelFormatRGBA8Unorm) {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::copy(t, t + 3, g_gbuf);
    }
}

void SetSharpness(float amount)
{
    amount = std::clamp(amount, 0.0f, 1.0f);
    if (g_sharpness.exchange(amount) != amount) {
        Logger::Info("Denoise: sharpening " + std::to_string(amount));
    }
}

// RCAS on the scaler's output: copy it, then sharpen the copy back into it.
void Sharpen(id<MTLCommandBuffer> cb, id<MTLTexture> output)
{
    const float amount = g_sharpness.load(std::memory_order_relaxed);
    if (amount <= 0.0f || !g_rcas || !(output.usage & MTLTextureUsageShaderWrite) ||
        (output.textureType != MTLTextureType2D && output.textureType != MTLTextureType2DArray)) {
        return;
    }
    if (!g_sharpSrc || g_sharpSrc.width != output.width || g_sharpSrc.height != output.height ||
        g_sharpSrc.pixelFormat != output.pixelFormat) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:output.pixelFormat
                                                                                       width:output.width
                                                                                      height:output.height
                                                                                   mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        g_sharpSrc = [output.device newTextureWithDescriptor:td];
    }
    MetalTrace::Internal internal;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(output.width, output.height, 1) toTexture:g_sharpSrc destinationSlice:0
         destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:output.textureType == MTLTextureType2D ? g_rcas : g_rcasArray];
    [ce setTexture:g_sharpSrc atIndex:0];
    [ce setTexture:output atIndex:1];
    [ce setBytes:&amount length:sizeof(amount) atIndex:0];
    [ce dispatchThreads:MTLSizeMake(output.width, output.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding];
}

bool EncodeScaler(id scaler, id commandBuffer)
{
    const uint64_t frame = g_frame.fetch_add(1);
    g_scalerMs.store(NowMs());
    // Only while RELAX is being passed through (ray traced frames) and the guides are current. The game encodes on
    // several threads, so this frame's RELAX encoder may be encoded after this call: allow the previous frame.
    if (g_mode.load(std::memory_order_relaxed) != Fx || g_failed || !g_diffuse) {
        return false;
    }
    static std::atomic<uint64_t> denoised{0}, fallbacks{0};
    if ((frame & 1023) == 0 && denoised.load()) {
        Logger::Info("Denoise: last frames: " + std::to_string(denoised.exchange(0)) + " denoised, " +
                     std::to_string(fallbacks.exchange(0)) + " game scaler while RELAX was passed through");
    }
    if (frame - g_passFrame.load() > 1 || frame - g_guideFrame.load() > 1) {
        if (frame - g_passFrame.load() < 8) {
            fallbacks.fetch_add(1); // ray traced frame without this frame's pass-through or guides
        }
        return false;
    }
    denoised.fetch_add(1);
    if (@available(macOS 26.0, *)) {
        id<MTLFXTemporalScaler> s = scaler;
        id<MTLTexture> color = s.colorTexture, depth = s.depthTexture, motion = s.motionTexture,
                       output = s.outputTexture;
        if (g_diffuse.width != s.inputWidth || g_diffuse.height != s.inputHeight) {
            return false; // G-buffer at another size (resolution change in progress)
        }
        id<MTLFXTemporalDenoisedScaler> ds = g_scaler;
        if (!ds || ds.inputWidth != s.inputWidth || ds.inputHeight != s.inputHeight ||
            ds.outputWidth != s.outputWidth || ds.outputHeight != s.outputHeight ||
            ds.colorTextureFormat != color.pixelFormat || ds.motionTextureFormat != motion.pixelFormat) {
            MTLFXTemporalDenoisedScalerDescriptor* d = [MTLFXTemporalDenoisedScalerDescriptor new];
            d.colorTextureFormat = color.pixelFormat;
            d.depthTextureFormat = depth.pixelFormat;
            d.motionTextureFormat = motion.pixelFormat;
            d.diffuseAlbedoTextureFormat = g_diffuse.pixelFormat;
            d.specularAlbedoTextureFormat = g_specular.pixelFormat;
            d.normalTextureFormat = g_normal.pixelFormat;
            d.roughnessTextureFormat = g_roughness.pixelFormat;
            d.outputTextureFormat = output.pixelFormat;
            d.inputWidth = s.inputWidth;
            d.inputHeight = s.inputHeight;
            d.outputWidth = s.outputWidth;
            d.outputHeight = s.outputHeight;
            d.requiresSynchronousInitialization = YES;
            ds = [d newTemporalDenoisedScalerWithDevice:color.device];
            auto fits = [](id<MTLTexture> t, MTLTextureUsage need) { return (t.usage & need) == need; };
            if (!ds || !fits(color, ds.colorTextureUsage) || !fits(depth, ds.depthTextureUsage) ||
                !fits(motion, ds.motionTextureUsage) || !fits(output, ds.outputTextureUsage)) {
                Logger::Error("Denoise: denoised scaler unavailable for the game's textures (created " +
                              std::to_string(ds != nil) + ", output usage " + std::to_string(output.usage) + ")");
                g_failed = true;
                return false;
            }
            g_scaler = ds;
            char buf[200];
            std::snprintf(buf, sizeof(buf), "Denoise: denoised scaler %lux%lu -> %lux%lu (color %lu, depth %lu, motion %lu)",
                          (unsigned long)s.inputWidth, (unsigned long)s.inputHeight, (unsigned long)s.outputWidth,
                          (unsigned long)s.outputHeight, (unsigned long)color.pixelFormat,
                          (unsigned long)depth.pixelFormat, (unsigned long)motion.pixelFormat);
            Logger::Info(buf);
        }
        simd_float4x4 worldToView = matrix_identity_float4x4, viewToClip = matrix_identity_float4x4;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_cam.serial && g_camMode.load() != CamIdentity) {
                worldToView = simd_inverse(g_cam.viewToWorld);
                viewToClip = simd_mul(g_cam.worldToClip, g_cam.viewToWorld);
                if (g_camMode.load() == CamRightHanded) { // view space looking down -z
                    const simd_float4x4 flip = simd_diagonal_matrix(simd_make_float4(1, 1, -1, 1));
                    worldToView = simd_mul(flip, worldToView);
                    viewToClip = simd_mul(viewToClip, flip);
                }
            }
        }
        ds.colorTexture = color;
        ds.depthTexture = depth;
        ds.motionTexture = motion;
        ds.diffuseAlbedoTexture = g_diffuse;
        ds.specularAlbedoTexture = g_specular;
        ds.normalTexture = g_normal;
        ds.roughnessTexture = g_roughness;
        ds.outputTexture = output;
        ds.exposureTexture = s.exposureTexture;
        ds.preExposure = s.preExposure;
        ds.jitterOffsetX = s.jitterOffsetX;
        ds.jitterOffsetY = s.jitterOffsetY;
        ds.motionVectorScaleX = s.motionVectorScaleX;
        ds.motionVectorScaleY = s.motionVectorScaleY;
        ds.depthReversed = s.isDepthReversed;
        ds.shouldResetHistory = s.reset;
        ds.worldToViewMatrix = worldToView;
        ds.viewToClipMatrix = viewToClip;
        [ds encodeToCommandBuffer:commandBuffer];
        Sharpen(commandBuffer, output);
        return true;
    }
    return false;
}

} // namespace Denoise
