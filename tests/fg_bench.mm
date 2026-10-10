// GPU cost of each part of frame generation (FrameGen.mm) at the game's sizes and formats.
//
//     ./build/fg_bench [frames]
//
// Each part runs in its own command buffer, timed with GPUStartTime/GPUEndTime; the first 30 are dropped. Formats as
// the game's (log: presents RGBA16Float, color 115): color RGBA16Float, depth Depth32Float, motion RG16Float, UI layer
// RGBA8Unorm_sRGB 2D array with 5 mips.

#include "FrameGenHud.h"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <simd/simd.h>

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

// Fills a texture with 16-bit values through a staging buffer: small positive halves, or `value` when given.
static void Fill(id<MTLCommandQueue> q, id<MTLTexture> t, size_t bpp, int value = -1)
{
    const NSUInteger row = t.width * bpp;
    id<MTLBuffer> b = [q.device newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    auto* p = static_cast<uint16_t*>(b.contents);
    for (size_t i = 0; i < b.length / 2; ++i) {
        p[i] = value >= 0 ? (uint16_t)value : (uint16_t)(0x3000 + (rand() & 0x7ff));
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

template <class Encode> static double Time(id<MTLCommandQueue> q, int frames, Encode encode)
{
    std::vector<double> ms;
    for (int i = 0; i < frames + 30; ++i) {
        id<MTLCommandBuffer> cb = [q commandBuffer];
        encode(cb, i);
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            fprintf(stderr, "command buffer error: %s\n", cb.error.localizedDescription.UTF8String);
            return -1;
        }
        if (i >= 30) {
            ms.push_back((cb.GPUEndTime - cb.GPUStartTime) * 1000.0);
        }
    }
    std::sort(ms.begin(), ms.end());
    return ms[ms.size() / 2];
}

static id<MTLFXFrameInterpolator> Interpolator(id<MTLDevice> d, NSUInteger iw, NSUInteger ih, NSUInteger ow,
                                               NSUInteger oh)
{
    MTLFXFrameInterpolatorDescriptor* fd = [MTLFXFrameInterpolatorDescriptor new];
    fd.colorTextureFormat = MTLPixelFormatRGBA16Float;
    fd.outputTextureFormat = MTLPixelFormatRGBA16Float;
    fd.depthTextureFormat = MTLPixelFormatDepth32Float;
    fd.motionTextureFormat = MTLPixelFormatRG16Float;
    fd.inputWidth = iw;
    fd.inputHeight = ih;
    fd.outputWidth = ow;
    fd.outputHeight = oh;
    return [fd newFrameInterpolatorWithDevice:d];
}

int main(int argc, char** argv)
{
    @autoreleasepool {
        const int frames = argc > 1 ? atoi(argv[1]) : 100;
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [d newCommandQueue];
        if (![MTLFXFrameInterpolatorDescriptor supportsDevice:d]) {
            printf("%s: frame interpolation not supported\n", d.name.UTF8String);
            return 1;
        }
        const NSUInteger ow = 3456, oh = 2160;
        const MTLTextureUsage rw = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        const MTLPixelFormat color = MTLPixelFormatRGBA16Float;
        id<MTLTexture> game = Make(d, color, ow, oh, rw), cur = Make(d, color, ow, oh, rw),
                       prev = Make(d, color, ow, oh, rw), out = Make(d, color, ow, oh, rw),
                       drawA = Make(d, color, ow, oh, rw),
                       drawB = Make(d, color, ow, oh, rw);
        for (id<MTLTexture> t : {game, cur, prev}) {
            Fill(q, t, 8);
        }
        printf("%s, output %lux%lu RGBA16Float, median of %d\n\n| Part | ms |\n| --- | ---: |\n", d.name.UTF8String,
               (unsigned long)ow, (unsigned long)oh, frames);

        printf("| full-screen copy | %.3f |\n", Time(q, frames, [&](id<MTLCommandBuffer> cb, int) {
                   id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                   [b copyFromTexture:game toTexture:cur];
                   [b endEncoding];
               }));

        struct In {
            const char* name;
            NSUInteger iw, ih, ow, oh;
        };
        id<MTLTexture> depth, motion;
        for (In s : {In{"interpolator, input 2.25x", 1536, 960, ow, oh}, In{"interpolator, input 3x", 1152, 720, ow, oh},
                     In{"interpolator, input 2x", 1728, 1080, ow, oh},
                     In{"interpolator at half output (1728x1080), input 2.25x", 1536, 960, ow / 2, oh / 2}}) {
            id<MTLTexture> z = Make(d, MTLPixelFormatDepth32Float, s.iw, s.ih, MTLTextureUsageRenderTarget),
                           m = Make(d, MTLPixelFormatRG16Float, s.iw, s.ih, rw);
            Fill(q, m, 4);
            if (s.iw == 1536 && s.ow == ow) {
                depth = z;
                motion = m;
            }
            id<MTLTexture> c = cur, p = prev, o = out;
            if (s.ow != ow) {
                c = Make(d, color, s.ow, s.oh, rw);
                p = Make(d, color, s.ow, s.oh, rw);
                o = Make(d, color, s.ow, s.oh, rw);
                Fill(q, c, 8);
                Fill(q, p, 8);
            }
            id<MTLFXFrameInterpolator> fi = Interpolator(d, s.iw, s.ih, s.ow, s.oh);
            fi.depthTexture = z;
            fi.motionTexture = m;
            fi.outputTexture = o;
            fi.motionVectorScaleX = s.iw;
            fi.motionVectorScaleY = s.ih;
            fi.deltaTime = 1 / 30.0f;
            fi.nearPlane = 0.02f;
            fi.farPlane = 20000.0f;
            fi.fieldOfView = 60.0f;
            fi.aspectRatio = (float)s.ow / s.oh;
            fi.depthReversed = YES;
            printf("| %s | %.3f |\n", s.name, Time(q, frames, [&](id<MTLCommandBuffer> cb, int i) {
                       fi.colorTexture = i % 2 ? c : p;
                       fi.prevColorTexture = i % 2 ? p : c;
                       fi.shouldResetHistory = i == 0;
                       [fi encodeToCommandBuffer:cb];
                   }));
        }

        // The HUD restore (fg_hud) and the UI snapshot copies (fg_ui_copy_array), as FrameGen runs them.
        NSError* error = nil;
        id<MTLLibrary> lib = [d newLibraryWithSource:kHudSource options:nil error:&error];
        id<MTLComputePipelineState> hud = [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fg_hud"]
                                                                            error:&error],
                                    copyArray = [d newComputePipelineStateWithFunction:
                                                       [lib newFunctionWithName:@"fg_ui_copy_array"] error:&error];
        if (!hud || !copyArray) {
            fprintf(stderr, "HUD kernels: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        MTLTextureDescriptor* ud = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                                                                       width:ow height:oh mipmapped:YES];
        ud.textureType = MTLTextureType2DArray;
        ud.arrayLength = 1;
        ud.mipmapLevelCount = 5;
        ud.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        ud.storageMode = MTLStorageModePrivate;
        id<MTLTexture> uiLayer = [d newTextureWithDescriptor:ud];
        id<MTLTexture> snap = Make(d, MTLPixelFormatR8Unorm, ow, oh, MTLTextureUsageShaderWrite),
                       snapLow = Make(d, MTLPixelFormatR8Unorm, ow >> 4, oh >> 4, MTLTextureUsageShaderWrite);
        printf("| UI snapshot copies (level 0 and 16x mip) | %.3f |\n", Time(q, frames, [&](id<MTLCommandBuffer> cb, int) {
                   id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                   [ce setComputePipelineState:copyArray];
                   [ce setTexture:uiLayer atIndex:0];
                   for (uint32_t lod : {0u, 4u}) {
                       id<MTLTexture> dst = lod ? snapLow : snap;
                       [ce setTexture:dst atIndex:1];
                       [ce setBytes:&lod length:sizeof(lod) atIndex:0];
                       [ce dispatchThreads:MTLSizeMake(dst.width, dst.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
                   }
                   [ce endEncoding];
               }));
        id<MTLFence> fence = getenv("FG_BENCH_FENCE") ? [d newFence] : nil; // as FrameGen (interpolator fence)
        auto hudPass = [&](id<MTLCommandBuffer> cb, float mv) {
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            if (fence) {
                [ce waitForFence:fence];
            }
            [ce setComputePipelineState:hud];
            [ce setTexture:out atIndex:0];
            [ce setTexture:cur atIndex:1];
            [ce setTexture:snap atIndex:2];
            [ce setTexture:snapLow atIndex:3];
            [ce setTexture:motion atIndex:4];
            [ce setTexture:drawA atIndex:5];
            struct {
                uint32_t debug, hasLow;
                simd_float2 mvToOut, outToIn;
            } params = {0, 1, simd_make_float2(mv, mv), simd_make_float2(1536.0f / ow, 960.0f / oh)};
            [ce setBytes:&params length:sizeof(params) atIndex:0];
            [ce dispatchThreads:MTLSizeMake(ow, oh, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [ce endEncoding];
        };
        // Motion is noise of about 0.1-1 render pixels: scale 0 skips the motion path, 30 takes it everywhere.
        printf("| HUD restore, still | %.3f |\n", Time(q, frames, [&](id<MTLCommandBuffer> cb, int) { hudPass(cb, 0); }));
        printf("| HUD restore, moving | %.3f |\n", Time(q, frames, [&](id<MTLCommandBuffer> cb, int) { hudPass(cb, 30); }));

        // Everything FrameGen does per rendered frame, in one command buffer (as in the game's).
        id<MTLFXFrameInterpolator> fi = Interpolator(d, 1536, 960, ow, oh);
        fi.depthTexture = depth;
        fi.motionTexture = motion;
        fi.outputTexture = out;
        fi.motionVectorScaleX = 1536;
        fi.motionVectorScaleY = 960;
        fi.deltaTime = 1 / 30.0f;
        fi.nearPlane = 0.02f;
        fi.farPlane = 20000.0f;
        fi.fieldOfView = 60.0f;
        fi.aspectRatio = (float)ow / oh;
        fi.depthReversed = YES;
        fi.fence = fence;
        printf("| all of it (moving), one command buffer | %.3f |\n", Time(q, frames, [&](id<MTLCommandBuffer> cb, int i) {
                   id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                   [b copyFromTexture:game toTexture:i % 2 ? cur : prev];
                   [b endEncoding];
                   fi.colorTexture = i % 2 ? cur : prev;
                   fi.prevColorTexture = i % 2 ? prev : cur;
                   fi.shouldResetHistory = i == 0;
                   [fi encodeToCommandBuffer:cb];
                   hudPass(cb, 30); // into the generated drawable
                   b = [cb blitCommandEncoder];
                   [b copyFromTexture:i % 2 ? cur : prev toTexture:drawB];
                   [b endEncoding];
               }));
    }
    return 0;
}
