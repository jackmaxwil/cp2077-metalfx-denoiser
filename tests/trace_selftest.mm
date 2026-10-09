// Self-test for MetalTrace: runs a small Metal workload through every hooked path and checks the trace and perf
// files. Build target trace_selftest; run it from the build folder: ./trace_selftest
// (MTL_CAPTURE_ENABLED=1 ./trace_selftest also checks the GPU capture.)
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "Denoise.hpp"
#include "FrameGen.hpp"
#import <MetalFX/MetalFX.h>
#include "MetalTrace.hpp"

static const char* kSource = R"(
#include <metal_stdlib>
using namespace metal;
kernel void selftest_kernel(texture2d<float, access::read> gIn_Color [[texture(0)]],
                            texture2d<float, access::write> gOut_Color [[texture(1)]],
                            uint2 id [[thread_position_in_grid]])
{
    gOut_Color.write(gIn_Color.read(id) * 0.5, id);
}
)";

static std::string Slurp(const std::string& path)
{
    std::ifstream f(path);
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

static int Fail(const char* what)
{
    std::fprintf(stderr, "FAIL: %s\n", what);
    return 1;
}

int main()
{
    @autoreleasepool {
        if (!MetalTrace::Install()) {
            return Fail("install");
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSource) options:nil error:&err];
        id<MTLFunction> fn = [lib newFunctionWithName:@"selftest_kernel"];
        // Every compute creation path; the last one is used for the frames.
        id<MTLComputePipelineState> a = [dev newComputePipelineStateWithFunction:fn error:&err];
        MTLComputePipelineDescriptor* desc = [MTLComputePipelineDescriptor new];
        desc.computeFunction = fn;
        desc.label = @"selftest-desc";
        id<MTLComputePipelineState> b = [dev newComputePipelineStateWithDescriptor:desc
                                                                           options:MTLPipelineOptionNone
                                                                        reflection:nil
                                                                             error:&err];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block id<MTLComputePipelineState> c = nil;
        [dev newComputePipelineStateWithFunction:fn
                               completionHandler:^(id<MTLComputePipelineState> pso, NSError*) {
                                 c = [pso retain];
                                 dispatch_semaphore_signal(done);
                               }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (!a || !b || !c) {
            return Fail("pipeline creation");
        }

        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:64
                                                                                     height:32
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> in = [dev newTextureWithDescriptor:td];
        id<MTLTexture> out = [dev newTextureWithDescriptor:td];
        CAMetalLayer* layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.drawableSize = CGSizeMake(64, 32);
        id<MTLCommandQueue> queue = [dev newCommandQueue];

        // Requests are read every 15 frames.
        const std::string dir = "trace";
        std::ofstream(dir + "/req-1") << "trace selftest\n";
        for (int frame = 0; frame < 40; ++frame) {
            @autoreleasepool {
                if (frame == 20) {
                    std::ofstream(dir + "/req-2") << "perf selftest 8\n";
                }
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                [cb pushDebugGroup:@"SelftestPass"];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:c];
                [enc setTexture:in atIndex:0];
                [enc setTexture:out atIndex:1];
                [enc dispatchThreadgroups:MTLSizeMake(8, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [enc endEncoding];
                [cb popDebugGroup];
                id<CAMetalDrawable> drawable = [layer nextDrawable];
                if (drawable) {
                    [cb presentDrawable:drawable];
                }
                [cb commit];
                [cb waitUntilCompleted];
            }
        }
        sleep(3);

        // Dump: a frame with a two-target render pass (RGBA8 cleared to red, BGR10A2 2D array to green).
        MTLTextureDescriptor* rtd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:32
                                                                                     height:16
                                                                                  mipmapped:NO];
        rtd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> rt0 = [dev newTextureWithDescriptor:rtd];
        rtd.pixelFormat = MTLPixelFormatBGR10A2Unorm;
        rtd.textureType = MTLTextureType2DArray; // like the game's render targets
        id<MTLTexture> rt1 = [dev newTextureWithDescriptor:rtd];
        std::ofstream(dir + "/req-3") << "dump selftestdump selftest_kernel\n";
        for (int frame = 0; frame < 20; ++frame) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = rt0;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.colorAttachments[1].texture = rt1;
                rp.colorAttachments[1].loadAction = MTLLoadActionClear;
                rp.colorAttachments[1].clearColor = MTLClearColorMake(0, 1, 0, 1);
                rp.colorAttachments[1].storeAction = MTLStoreActionStore;
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder]; // dispatch textures, by function name
                [enc setComputePipelineState:c];
                [enc useResource:in usage:MTLResourceUsageRead];
                [enc useResource:out usage:MTLResourceUsageWrite];
                [enc setTexture:in atIndex:0];
                [enc setTexture:out atIndex:1];
                [enc dispatchThreadgroups:MTLSizeMake(8, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [enc endEncoding];
                id<CAMetalDrawable> drawable = [layer nextDrawable];
                if (drawable) {
                    [cb presentDrawable:drawable];
                }
                [cb commit];
                [cb waitUntilCompleted];
            }
        }
        sleep(1);
        if (access((dir + "/selftestdump-00-rt0-32x16-RGBA8Unorm.png").c_str(), F_OK) != 0 ||
            access((dir + "/selftestdump-01-rt1-32x16-BGR10A2Unorm.png").c_str(), F_OK) != 0 ||
            access((dir + "/selftestdump-02-selftest_kernel-r-64x32-RGBA16Float.png").c_str(), F_OK) != 0 ||
            access((dir + "/selftestdump-03-selftest_kernel-w-64x32-RGBA16Float.png").c_str(), F_OK) != 0) {
            return Fail("dump PNGs missing");
        }

        if (getenv("MTL_CAPTURE_ENABLED")) {
            std::ofstream(dir + "/req-4") << "capture selftest\n";
            for (int frame = 0; frame < 20; ++frame) {
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<CAMetalDrawable> drawable = [layer nextDrawable];
                    if (drawable) {
                        [cb presentDrawable:drawable];
                    }
                    [cb commit];
                    [cb waitUntilCompleted];
                }
            }
            if (access((dir + "/selftest.gputrace").c_str(), F_OK) != 0) {
                return Fail("no selftest.gputrace");
            }
        }

        const std::string trace = Slurp(dir + "/selftest.trace.jsonl");
        if (trace.find("\"e\":\"d\"") == std::string::npos) {
            return Fail("no dispatch in selftest.trace.jsonl");
        }
        if (trace.find("\"name\":\"selftest_kernel\"") == std::string::npos) {
            return Fail("pipeline not named");
        }
        if (trace.find("\"gIn_Color\",\"r\"") == std::string::npos || trace.find("\"gOut_Color\",\"w\"") == std::string::npos) {
            return Fail("binding names or access missing");
        }
        if (trace.find("\"fmt\":\"RGBA16Float\"") == std::string::npos) {
            return Fail("texture description missing");
        }
        if (trace.find("\"grp\":\"SelftestPass\"") == std::string::npos) {
            return Fail("command buffer debug group missing");
        }
        const std::string perf = Slurp(dir + "/selftest.perf.json");
        if (perf.find("\"gpu_ms\":{\"median\":") == std::string::npos || perf.find("\"n\":0") != std::string::npos) {
            return Fail("perf output missing or empty");
        }
        // GPU timestamps per encoder: a profiled frame resolves its encoders' start and end samples 30 frames later.
        {
            std::ofstream(dir + "/req-5") << "profile selftestprof\n";
            for (int frame = 0; frame < 80; ++frame) {
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    [enc setComputePipelineState:c];
                    [enc setTexture:in atIndex:0];
                    [enc setTexture:out atIndex:1];
                    [enc dispatchThreadgroups:MTLSizeMake(8, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                    [enc endEncoding];
                    id<CAMetalDrawable> drawable = [layer nextDrawable];
                    if (drawable) {
                        [cb presentDrawable:drawable];
                    }
                    [cb commit];
                    [cb waitUntilCompleted];
                }
            }
            const std::string ts = Slurp(dir + "/selftestprof.ts.json");
            const std::string tr = Slurp(dir + "/selftestprof.trace.jsonl");
            if (ts.find("\"samples\":[") == std::string::npos || ts.find("\"samples\":[]") != std::string::npos ||
                ts.find("\"samples\":[null") != std::string::npos || tr.find("\"ts\":0") == std::string::npos) {
                std::fprintf(stderr, "%s\n", ts.substr(0, 300).c_str());
                return Fail("profile timestamps missing");
            }
        }

        // Frame generation: with a MetalFX temporal scaler call and a present every frame, frames are generated (the
        // first presents only turn off the layer's framebufferOnly and fill the history).
        {
            MTLFXTemporalScalerDescriptor* sd = [[MTLFXTemporalScalerDescriptor new] autorelease];
            sd.colorTextureFormat = MTLPixelFormatRGBA16Float;
            sd.depthTextureFormat = MTLPixelFormatDepth32Float;
            sd.motionTextureFormat = MTLPixelFormatRG16Float;
            sd.outputTextureFormat = MTLPixelFormatRGBA16Float;
            sd.inputWidth = 32;
            sd.inputHeight = 16;
            sd.outputWidth = 64;
            sd.outputHeight = 32;
            id<MTLFXTemporalScaler> ts = [sd newTemporalScalerWithDevice:dev];
            MTLTextureDescriptor* fd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                          width:32
                                                                                         height:16
                                                                                      mipmapped:NO];
            fd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            fd.storageMode = MTLStorageModePrivate;
            id<MTLTexture> fc = [dev newTextureWithDescriptor:fd];
            fd.pixelFormat = MTLPixelFormatRG16Float;
            id<MTLTexture> fm = [dev newTextureWithDescriptor:fd];
            fd.pixelFormat = MTLPixelFormatDepth32Float;
            id<MTLTexture> fz = [dev newTextureWithDescriptor:fd];
            fd.pixelFormat = MTLPixelFormatRGBA16Float;
            fd.width = 64;
            fd.height = 32;
            fd.usage = ts.outputTextureUsage | MTLTextureUsageShaderRead;
            id<MTLTexture> fo = [dev newTextureWithDescriptor:fd];
            CAMetalLayer* fl = [CAMetalLayer layer];
            fl.device = dev;
            fl.pixelFormat = MTLPixelFormatRGBA16Float;
            fl.drawableSize = CGSizeMake(64, 32);
            FrameGen::SetEnabled(true);
            const auto before = FrameGen::Generated();
            for (int frame = 0; frame < 12; ++frame) {
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    ts.colorTexture = fc;
                    ts.depthTexture = fz;
                    ts.motionTexture = fm;
                    ts.outputTexture = fo;
                    [ts encodeToCommandBuffer:cb];
                    id<CAMetalDrawable> drawable = [fl nextDrawable];
                    if (drawable) {
                        [cb presentDrawable:drawable];
                    }
                    [cb commit];
                    [cb waitUntilCompleted];
                }
            }
            FrameGen::SetEnabled(false);
            if (FrameGen::Generated() - before < 8) {
                std::fprintf(stderr, "generated %llu\n", FrameGen::Generated() - before);
                return Fail("frame generation produced no frames");
            }
        }

        // Denoise pass-through: a RELAX instance (pipelines labelled like the game's HitDistReconstruction and last
        // a-trous pass) is dropped, and its two RGBA16Float inputs are copied to its two outputs.
        {
            MTLComputePipelineDescriptor* pd = [MTLComputePipelineDescriptor new];
            pd.computeFunction = fn;
            pd.label = @"2684890295";
            id<MTLComputePipelineState> hitDist = [dev newComputePipelineStateWithDescriptor:pd
                                                                                     options:MTLPipelineOptionNone
                                                                                  reflection:nil
                                                                                       error:&err];
            pd.label = @"1624964913";
            id<MTLComputePipelineState> prePass = [dev newComputePipelineStateWithDescriptor:pd
                                                                                     options:MTLPipelineOptionNone
                                                                                  reflection:nil
                                                                                       error:&err];
            pd.label = @"1807644384";
            id<MTLComputePipelineState> atrous = [dev newComputePipelineStateWithDescriptor:pd
                                                                                    options:MTLPipelineOptionNone
                                                                                 reflection:nil
                                                                                      error:&err];
            MTLTextureDescriptor* ad = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                          width:8
                                                                                         height:4
                                                                                      mipmapped:NO];
            ad.textureType = MTLTextureType2DArray;
            ad.storageMode = MTLStorageModeShared;
            ad.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            id<MTLTexture> t[4];
            for (int i = 0; i < 4; ++i) {
                t[i] = [dev newTextureWithDescriptor:ad];
                std::vector<__fp16> px(8 * 4 * 4, (__fp16)(i < 2 ? i + 1 : 0));
                [t[i] replaceRegion:MTLRegionMake2D(0, 0, 8, 4) mipmapLevel:0 slice:0 withBytes:px.data()
                        bytesPerRow:8 * 8 bytesPerImage:8 * 8 * 4];
            }
            // Raw inputs (PrePass dropped): HitDistReconstruction's two reads are copied.
            Denoise::SetMode("pass");
            Denoise::SetPrepass(false);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc useResources:t count:2 usage:MTLResourceUsageRead];
            [enc setComputePipelineState:hitDist];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
            [enc useResources:t + 2 count:2 usage:MTLResourceUsageRead | MTLResourceUsageWrite];
            [enc setComputePipelineState:atrous];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            Denoise::SetPrepass(true);
            Denoise::SetMode("off");
            __fp16 o[2][4];
            for (int i = 0; i < 2; ++i) {
                [t[2 + i] getBytes:o[i] bytesPerRow:8 * 8 bytesPerImage:8 * 8 * 4
                         fromRegion:MTLRegionMake2D(7, 3, 1, 1) mipmapLevel:0 slice:0];
            }
            const bool lowFirst = t[0] < t[1], outLowFirst = t[2] < t[3]; // inputs and outputs pair by address
            const float want0 = (lowFirst == outLowFirst) ? 1 : 2;
            if ((float)o[0][0] != want0 || (float)o[1][0] != 3 - want0 || (float)o[0][3] != want0) {
                std::fprintf(stderr, "denoise outputs %.1f %.1f\n", (float)o[0][0], (float)o[1][0]);
                return Fail("denoise pass-through did not copy the inputs");
            }

            // PrePass kept (the default): its two written textures are copied, in reverse address order. The kept dispatches run the self-test
            // kernel, so they get real textures to work on.
            for (int i = 0; i < 4; ++i) {
                std::vector<__fp16> px(8 * 4 * 4, (__fp16)(i < 2 ? 5 + i : 0));
                [t[i] replaceRegion:MTLRegionMake2D(0, 0, 8, 4) mipmapLevel:0 slice:0 withBytes:px.data()
                        bytesPerRow:8 * 8 bytesPerImage:8 * 8 * 4];
            }
            Denoise::SetMode("pass");
            cb = [queue commandBuffer];
            enc = [cb computeCommandEncoder];
            [enc setTexture:in atIndex:0];
            [enc setTexture:out atIndex:1];
            [enc setComputePipelineState:hitDist];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
            [enc useResources:t count:2 usage:MTLResourceUsageRead | MTLResourceUsageWrite];
            [enc setComputePipelineState:prePass];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
            [enc useResources:t + 2 count:2 usage:MTLResourceUsageRead | MTLResourceUsageWrite];
            [enc setComputePipelineState:atrous];
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 4, 1)];
            [enc endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            Denoise::SetMode("off");
            for (int i = 0; i < 2; ++i) {
                [t[2 + i] getBytes:o[i] bytesPerRow:8 * 8 bytesPerImage:8 * 8 * 4
                         fromRegion:MTLRegionMake2D(7, 3, 1, 1) mipmapLevel:0 slice:0];
            }
            const float want5 = (lowFirst == outLowFirst) ? 6 : 5; // path tracing pairs PrePass's outputs reversed
            if ((float)o[0][0] != want5 || (float)o[1][0] != 11 - want5) {
                std::fprintf(stderr, "denoise prepass outputs %.1f %.1f\n", (float)o[0][0], (float)o[1][0]);
                return Fail("denoise pass-through did not copy the PrePass outputs");
            }
        }
        std::printf("PASS trace_selftest (%zu trace bytes)\n%s", trace.size(), perf.c_str());
        return 0;
    }
}
