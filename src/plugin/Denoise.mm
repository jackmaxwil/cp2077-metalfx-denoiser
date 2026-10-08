// Path tracing denoiser prototype: NRD pass-through plus MetalFX's temporal denoised scaler. Built with ARC.
//
// Modes (environment METALFX_DENOISE, or the tracer request "denoise off|pass|fx"):
// - pass: path tracing's RELAX dispatches are dropped, and each RELAX instance's noisy inputs are copied to its outputs,
//   so the game composites noisy lighting. The game's MetalFX temporal scaler still runs.
// - fx: pass, plus the game's MetalFX temporal scaler call is replaced by MTLFXTemporalDenoisedScaler (macOS 26), fed
//   guide textures made from the G-buffer.
//
// Path tracing's RELAX runs in one serial compute encoder (RED4ext/runs/20261008-131010-dump): two instances, each
// starting with HitDistReconstruction (label 2684890295, first instance only) or PrePass (1624964913), which read the
// two noisy RGBA16Float radiance textures (diffuse, specular), and ending with four a-trous iterations (1807644384),
// the last of which writes the instance's two outputs. Every dispatch from an instance's first pass to its last a-trous
// iteration is dropped; the copies are encoded into the same encoder just before it ends, after a texture barrier.
// The labels are the engine's compute pipeline labels, stable across runs; nothing happens if they are not seen.
//
// G-buffer (PIPELINE_TRACE_FINDINGS.md): render passes with BGR10A2Unorm, BGR10A2Unorm, RGBA8Unorm targets hold base
// color, world-space normal (xyz * 0.5 + 0.5) and metalness (R) / roughness (G). The guide textures are written from
// them in the RELAX encoder too, where the G-buffer is certainly alive.
//
// ponytail: camera matrices are identity (world-space normals passed as view-space); find the engine's view and
// projection matrices if the denoiser needs them.

#include "Denoise.hpp"
#include "Logger.hpp"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {

enum Mode { Off, Pass, Fx };
std::atomic<int> g_mode{Off};

const std::string kHitDist = "2684890295", kPrePass = "1624964913", kAtrous = "1807644384";

struct Job {
    id<MTLTexture> in[2], out[2];
};

struct Enc {
    std::string label;
    std::vector<std::pair<__unsafe_unretained id, unsigned long>> uses;
    bool open = false;
    int atrous = 0;
    std::vector<id<MTLTexture>> in, out;
    std::vector<Job> jobs;
};

std::mutex g_mutex;
std::unordered_map<const void*, Enc> g_enc;
id<MTLTexture> g_gbuf[3];
std::atomic<int> g_logged{0};
bool g_failed = false; // fx: setup failed, the game's scaler runs

id<MTLComputePipelineState> g_copy, g_guides;
id<MTLTexture> g_diffuse, g_specular, g_normal, g_roughness; // guide textures, input size
id g_scaler;                                                  // id<MTLFXTemporalDenoisedScaler>

NSString* const kSource = @R"(
#include <metal_stdlib>
using namespace metal;

kernel void mfxd_copy(texture2d_array<half, access::read> a [[texture(0)]],
                      texture2d_array<half, access::read> b [[texture(1)]],
                      texture2d_array<half, access::write> oa [[texture(2)]],
                      texture2d_array<half, access::write> ob [[texture(3)]],
                      uint2 p [[thread_position_in_grid]])
{
    if (p.x >= oa.get_width() || p.y >= oa.get_height()) return;
    oa.write(a.read(p, 0), p, 0);
    ob.write(b.read(p, 0), p, 0);
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
    }
    if (!g_copy || !g_guides) {
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
    if (e.in.size() == 2 && e.out.size() == 2) {
        e.jobs.push_back({{e.in[0], e.in[1]}, {e.out[0], e.out[1]}});
    } else if (g_logged.fetch_add(1) < 4) {
        Logger::Warn("Denoise: RELAX instance with " + std::to_string(e.in.size()) + " inputs and " +
                     std::to_string(e.out.size()) + " outputs; not copied");
    }
    e.open = false;
    e.atrous = 0;
    e.in.clear();
    e.out.clear();
}

bool Array(id<MTLTexture> t)
{
    return t.textureType == MTLTextureType2DArray;
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

bool Active()
{
    return g_mode.load(std::memory_order_relaxed) != Off;
}

void BindPipeline(id encoder, const std::string& label)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_enc[(__bridge const void*)encoder].label = label;
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

bool Dispatch(id encoder)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_enc.find((__bridge const void*)encoder);
    if (it == g_enc.end()) {
        return false;
    }
    Enc& e = it->second;
    const std::string& l = e.label;
    if (l == kHitDist || (l == kPrePass && (!e.open || e.atrous > 0))) {
        if (e.open) {
            Close(e);
        }
        e.open = true;
        e.in = Pick(e, false);
    } else if (e.open && e.atrous > 0 && l != kAtrous) {
        Close(e);
    }
    if (e.open && l == kAtrous) {
        ++e.atrous;
        e.out = Pick(e, true);
    }
    e.uses.clear();
    return e.open;
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
        if (!Array(j.in[0]) || !Array(j.in[1]) || !Array(j.out[0]) || !Array(j.out[1])) {
            continue;
        }
        for (NSUInteger i = 0; i < 2; ++i) {
            [ce setTexture:j.in[i] atIndex:i];
            [ce setTexture:j.out[i] atIndex:2 + i];
        }
        [ce dispatchThreads:MTLSizeMake(j.out[0].width, j.out[0].height, 1)
            threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    }
    if (g_mode.load() == Fx) {
        EncodeGuides(ce);
    }
    if (g_logged.fetch_add(1) == 0) {
        char buf[200];
        std::snprintf(buf, sizeof(buf), "Denoise: RELAX pass-through, %zu instances copied (%lux%lu)", jobs.size(),
                      (unsigned long)jobs[0].out[0].width, (unsigned long)jobs[0].out[0].height);
        Logger::Info(buf);
    }
    std::lock_guard<std::mutex> lock(g_mutex); // our own binds and dispatch re-created the entry
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

bool EncodeScaler(id scaler, id commandBuffer)
{
    if (g_mode.load(std::memory_order_relaxed) != Fx || g_failed || !g_diffuse) {
        return false;
    }
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
        ds.worldToViewMatrix = matrix_identity_float4x4;
        ds.viewToClipMatrix = matrix_identity_float4x4;
        [ds encodeToCommandBuffer:commandBuffer];
        return true;
    }
    return false;
}

} // namespace Denoise
