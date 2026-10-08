// GPU cost of MetalFX's temporal denoised scaler against its plain temporal scaler, at the game's sizes and formats.
//
//     ./build/denoiser_bench [frames]
//
// Inputs are noise (cost does not depend on content much); each frame is its own command buffer, timed with
// GPUStartTime/GPUEndTime; the first 30 frames are dropped. The game's inputs (PIPELINE_TRACE_FINDINGS.md): color
// RGBA16Float, depth Depth32Float_Stencil8 reversed, motion RG16Float; G-buffer BGR10A2Unorm/RGBA8Unorm targets.

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

static id<MTLTexture> Make(id<MTLDevice> d, MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage usage)
{
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h
                                                                              mipmapped:NO];
    td.usage = usage | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    return [d newTextureWithDescriptor:td];
}

// Fills a texture with noise through a shared staging buffer (depth formats are left as allocated).
static void Noise(id<MTLCommandQueue> q, id<MTLTexture> t, size_t bpp)
{
    if (!bpp) {
        return;
    }
    const NSUInteger row = t.width * bpp;
    id<MTLBuffer> b = [q.device newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    auto* p = static_cast<uint16_t*>(b.contents);
    for (size_t i = 0; i < b.length / 2; ++i) {
        p[i] = bpp == 8 ? (uint16_t)(0x3000 + (rand() & 0x7ff)) : (uint16_t)rand(); // RGBA16F: small positive halves
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row * t.height
              sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

struct Stats {
    double median, p90;
};

template <class Encode> static Stats Time(id<MTLCommandQueue> q, int frames, Encode encode)
{
    std::vector<double> ms;
    for (int i = 0; i < frames + 30; ++i) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        encode(cb, i);
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "command buffer error: %s\n", cb.error.localizedDescription.UTF8String);
            return {-1, -1};
        }
        if (i >= 30) {
            ms.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
        }
    }
    std::sort(ms.begin(), ms.end());
    return {ms[ms.size() / 2], ms[ms.size() * 9 / 10]};
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        const int frames = argc > 1 ? atoi(argv[1]) : 200;
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (![MTLFXTemporalDenoisedScalerDescriptor supportsDevice:d]) {
            printf("%s: temporal denoised scaler not supported\n", d.name.UTF8String);
            return 1;
        }
        printf("%s, denoised scaler input scale %.2f-%.2f, %d frames per row\n\n", d.name.UTF8String,
               [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMinScaleForDevice:d],
               [MTLFXTemporalDenoisedScalerDescriptor supportedInputContentMaxScaleForDevice:d], frames);
        printf("| Case | Input | Output | Temporal scaler ms | Denoised scaler ms (median/p90) |\n"
               "| --- | --- | --- | ---: | ---: |\n");

        struct Case {
            const char* name;
            NSUInteger iw, ih, ow, oh;
            MTLPixelFormat depth = MTLPixelFormatDepth32Float, normal = MTLPixelFormatRGBA16Float,
                           rough = MTLPixelFormatR16Float, albedo = MTLPixelFormatBGR10A2Unorm,
                           motion = MTLPixelFormatRG16Float;
            bool hit = true, autoExposure = false, plain = true;
        };
        std::vector<Case> cases = {
            {"base", 779, 487, 1168, 730},
            {"no hit distance", 779, 487, 1168, 730},
            {"8-bit normal/roughness/albedo", 779, 487, 1168, 730},
            {"game depth D32S8, RGBA16F motion", 779, 487, 1168, 730},
            {"auto exposure", 779, 487, 1168, 730},
            {"input 2x (Performance)", 584, 365, 1168, 730},
            {"input 3x (Ultra Performance)", 389, 243, 1168, 730},
            {"1080p Quality", 1152, 720, 1728, 1080},
            {"1080p Performance", 960, 540, 1920, 1080},
            {"1080p 3x", 640, 360, 1920, 1080},
            {"MBP16 Quality", 2304, 1489, 3456, 2234},
            {"MBP16 Performance", 1728, 1117, 3456, 2234},
            {"MBP16 3x", 1152, 745, 3456, 2234},
            {"denoise only 1080p", 1920, 1080, 1920, 1080},
        };
        cases[1].hit = false;
        cases[2].normal = MTLPixelFormatRGBA8Snorm;
        cases[2].rough = MTLPixelFormatR8Unorm;
        cases[2].albedo = MTLPixelFormatRGBA8Unorm;
        cases[3].depth = MTLPixelFormatDepth32Float_Stencil8;
        cases[3].motion = MTLPixelFormatRGBA16Float;
        cases[4].autoExposure = true;
        for (size_t i = 1; i < 5; ++i) {
            cases[i].plain = false;
        }
        auto bytes = [](MTLPixelFormat f) -> size_t {
            switch (f) {
            case MTLPixelFormatRGBA16Float: return 8;
            case MTLPixelFormatR16Float: return 2;
            case MTLPixelFormatR8Unorm: return 1;
            case MTLPixelFormatDepth32Float: case MTLPixelFormatDepth32Float_Stencil8: return 0;
            default: return 4;
            }
        };
        const MTLPixelFormat color = MTLPixelFormatRGBA16Float;
        for (const auto& s : cases) {
            const MTLTextureUsage rw = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
            id<MTLTexture> c = Make(d, color, s.iw, s.ih, rw), m = Make(d, s.motion, s.iw, s.ih, rw),
                           z = Make(d, s.depth, s.iw, s.ih, MTLTextureUsageRenderTarget),
                           da = Make(d, s.albedo, s.iw, s.ih, rw), sa = Make(d, s.albedo, s.iw, s.ih, rw),
                           n = Make(d, s.normal, s.iw, s.ih, rw), r = Make(d, s.rough, s.iw, s.ih, rw),
                           hit = Make(d, MTLPixelFormatR16Float, s.iw, s.ih, rw),
                           out = Make(d, color, s.ow, s.oh, MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget);
            for (id<MTLTexture> t : {c, m, da, sa, n, r, hit}) {
                Noise(q, t, bytes(t.pixelFormat));
            }

            Stats a{-1, -1}, b{-1, -1};
            if (s.plain) {
                MTLFXTemporalScalerDescriptor* td = [MTLFXTemporalScalerDescriptor new];
                td.colorTextureFormat = color;
                td.depthTextureFormat = s.depth;
                td.motionTextureFormat = s.motion;
                td.outputTextureFormat = color;
                td.inputWidth = s.iw;
                td.inputHeight = s.ih;
                td.outputWidth = s.ow;
                td.outputHeight = s.oh;
                td.requiresSynchronousInitialization = YES;
                if (id<MTLFXTemporalScaler> ts = [td newTemporalScalerWithDevice:d]) {
                    ts.colorTexture = c;
                    ts.depthTexture = z;
                    ts.motionTexture = m;
                    ts.outputTexture = out;
                    ts.depthReversed = YES;
                    ts.motionVectorScaleX = s.iw;
                    ts.motionVectorScaleY = s.ih;
                    ts.inputContentWidth = s.iw;
                    ts.inputContentHeight = s.ih;
                    a = Time(q, frames, [&](id<MTLCommandBuffer> cb, int i) {
                        ts.jitterOffsetX = (i % 8) / 8.0f - 0.5f;
                        ts.jitterOffsetY = (i % 3) / 3.0f - 0.5f;
                        [ts encodeToCommandBuffer:cb];
                    });
                }
            }

            MTLFXTemporalDenoisedScalerDescriptor* dd = [MTLFXTemporalDenoisedScalerDescriptor new];
            dd.colorTextureFormat = color;
            dd.depthTextureFormat = s.depth;
            dd.motionTextureFormat = s.motion;
            dd.diffuseAlbedoTextureFormat = s.albedo;
            dd.specularAlbedoTextureFormat = s.albedo;
            dd.normalTextureFormat = s.normal;
            dd.roughnessTextureFormat = s.rough;
            dd.specularHitDistanceTextureFormat = MTLPixelFormatR16Float;
            dd.specularHitDistanceTextureEnabled = s.hit;
            dd.autoExposureEnabled = s.autoExposure;
            dd.outputTextureFormat = color;
            dd.inputWidth = s.iw;
            dd.inputHeight = s.ih;
            dd.outputWidth = s.ow;
            dd.outputHeight = s.oh;
            dd.requiresSynchronousInitialization = YES;
            if (id<MTLFXTemporalDenoisedScaler> ds = [dd newTemporalDenoisedScalerWithDevice:d]) {
                ds.colorTexture = c;
                ds.depthTexture = z;
                ds.motionTexture = m;
                ds.diffuseAlbedoTexture = da;
                ds.specularAlbedoTexture = sa;
                ds.normalTexture = n;
                ds.roughnessTexture = r;
                ds.specularHitDistanceTexture = s.hit ? hit : nil;
                ds.outputTexture = out;
                ds.depthReversed = YES;
                ds.motionVectorScaleX = s.iw;
                ds.motionVectorScaleY = s.ih;
                ds.worldToViewMatrix = matrix_identity_float4x4;
                ds.viewToClipMatrix = matrix_identity_float4x4;
                b = Time(q, frames, [&](id<MTLCommandBuffer> cb, int i) {
                    ds.jitterOffsetX = (i % 8) / 8.0f - 0.5f;
                    ds.jitterOffsetY = (i % 3) / 3.0f - 0.5f;
                    [ds encodeToCommandBuffer:cb];
                });
            }
            char ta[32] = "", tb[32] = "unavailable";
            if (a.median >= 0) {
                snprintf(ta, sizeof(ta), "%.2f", a.median);
            }
            if (b.median >= 0) {
                snprintf(tb, sizeof(tb), "%.2f / %.2f", b.median, b.p90);
            }
            printf("| %s | %lux%lu | %lux%lu | %s | %s |\n", s.name, (unsigned long)s.iw, (unsigned long)s.ih,
                   (unsigned long)s.ow, (unsigned long)s.oh, ta, tb);
            fflush(stdout);
        }
    }
    return 0;
}
