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
        printf("| Input | Output | Temporal scaler ms (median/p90) | Denoised scaler ms (median/p90) |\n"
               "| --- | --- | ---: | ---: |\n");

        const struct { NSUInteger iw, ih, ow, oh; } sizes[] = {
            {779, 487, 1168, 730},    // rtbench window, MetalFX Quality
            {1152, 720, 1728, 1080},  // 1080p output, Quality
            {1280, 800, 2560, 1600},  // 1600p output, Performance
            {1728, 1117, 3456, 2234}, // MacBook Pro 16 native, Performance
            {2304, 1489, 3456, 2234}, // MacBook Pro 16 native, Quality
            {1920, 1080, 1920, 1080}, // denoise only, no upscale
        };
        const MTLPixelFormat color = MTLPixelFormatRGBA16Float, motion = MTLPixelFormatRG16Float,
                             gbuf = MTLPixelFormatBGR10A2Unorm, rough = MTLPixelFormatR16Float;
        for (const auto& s : sizes) {
            const MTLTextureUsage rw = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
            id<MTLTexture> c = Make(d, color, s.iw, s.ih, rw), m = Make(d, motion, s.iw, s.ih, rw),
                           z = Make(d, MTLPixelFormatDepth32Float, s.iw, s.ih, MTLTextureUsageRenderTarget),
                           da = Make(d, gbuf, s.iw, s.ih, rw), sa = Make(d, gbuf, s.iw, s.ih, rw),
                           n = Make(d, MTLPixelFormatRGBA16Float, s.iw, s.ih, rw), r = Make(d, rough, s.iw, s.ih, rw),
                           hit = Make(d, rough, s.iw, s.ih, rw),
                           out = Make(d, color, s.ow, s.oh, MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget);
            Noise(q, c, 8);
            Noise(q, m, 4);
            Noise(q, da, 4);
            Noise(q, sa, 4);
            Noise(q, n, 8);
            Noise(q, r, 2);
            Noise(q, hit, 2);

            MTLFXTemporalScalerDescriptor* td = [MTLFXTemporalScalerDescriptor new];
            td.colorTextureFormat = color;
            td.depthTextureFormat = MTLPixelFormatDepth32Float;
            td.motionTextureFormat = motion;
            td.outputTextureFormat = color;
            td.inputWidth = s.iw;
            td.inputHeight = s.ih;
            td.outputWidth = s.ow;
            td.outputHeight = s.oh;
            td.requiresSynchronousInitialization = YES;
            id<MTLFXTemporalScaler> ts = [td newTemporalScalerWithDevice:d];

            MTLFXTemporalDenoisedScalerDescriptor* dd = [MTLFXTemporalDenoisedScalerDescriptor new];
            dd.colorTextureFormat = color;
            dd.depthTextureFormat = MTLPixelFormatDepth32Float;
            dd.motionTextureFormat = motion;
            dd.diffuseAlbedoTextureFormat = gbuf;
            dd.specularAlbedoTextureFormat = gbuf;
            dd.normalTextureFormat = MTLPixelFormatRGBA16Float;
            dd.roughnessTextureFormat = rough;
            dd.specularHitDistanceTextureFormat = rough;
            dd.specularHitDistanceTextureEnabled = YES;
            dd.outputTextureFormat = color;
            dd.inputWidth = s.iw;
            dd.inputHeight = s.ih;
            dd.outputWidth = s.ow;
            dd.outputHeight = s.oh;
            dd.requiresSynchronousInitialization = YES;
            id<MTLFXTemporalDenoisedScaler> ds = [dd newTemporalDenoisedScalerWithDevice:d];

            Stats a{-1, -1}, b{-1, -1};
            if (ts) {
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
            if (ds) {
                ds.colorTexture = c;
                ds.depthTexture = z;
                ds.motionTexture = m;
                ds.diffuseAlbedoTexture = da;
                ds.specularAlbedoTexture = sa;
                ds.normalTexture = n;
                ds.roughnessTexture = r;
                ds.specularHitDistanceTexture = hit;
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
            auto cell = [](Stats x) {
                static char buf[2][32];
                static int k = 0;
                k ^= 1;
                if (x.median < 0) {
                    snprintf(buf[k], sizeof(buf[k]), "unavailable");
                } else {
                    snprintf(buf[k], sizeof(buf[k]), "%.2f / %.2f", x.median, x.p90);
                }
                return buf[k];
            };
            printf("| %lux%lu | %lux%lu | %s | %s |\n", (unsigned long)s.iw, (unsigned long)s.ih,
                   (unsigned long)s.ow, (unsigned long)s.oh, cell(a), cell(b));
            fflush(stdout);
        }
    }
    return 0;
}
