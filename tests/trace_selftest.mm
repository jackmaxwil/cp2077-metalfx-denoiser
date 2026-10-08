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
        std::ofstream(dir + "/req-3") << "dump selftestdump\n";
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
            access((dir + "/selftestdump-01-rt1-32x16-BGR10A2Unorm.png").c_str(), F_OK) != 0) {
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
        std::printf("PASS trace_selftest (%zu trace bytes)\n%s", trace.size(), perf.c_str());
        return 0;
    }
}
