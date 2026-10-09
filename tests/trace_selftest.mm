// Self-test for MetalTrace: runs a small Metal workload through every hooked path and checks the trace and perf
// files. Build target trace_selftest; run it from the build folder: ./trace_selftest
// (MTL_CAPTURE_ENABLED=1 ./trace_selftest also checks the GPU capture.)
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdio>
#include <simd/simd.h>
#include <cmath>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

#include "Denoise.hpp"
#include "FrameGen.hpp"
#include "Input.hpp"
#include "Warp.hpp"
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

int main(int, char** argv)
{
    @autoreleasepool {
        // The tracer's request folder is trace/ next to the binary; the paths below are relative to it.
        const std::string self = argv[0];
        if (self.find('/') != std::string::npos && chdir(self.substr(0, self.rfind('/')).c_str()) != 0) {
            return Fail("chdir to the binary's folder");
        }
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
            // A HUD layer like the game's (output size, RGBA8 sRGB, drawn every frame): exercises the HUD restore.
            fd.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
            fd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            id<MTLTexture> fui = [dev newTextureWithDescriptor:fd];
            // Twice: plain, then with frame warp (a test camera and calibration, mouse movement every frame), where the
            // game's frame is presented late from a command buffer of the plugin's own.
            const float camV2w[16] = {0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1};
            const float camP[16] = {0.866f, 0, 0, 0, 0, 1.732f, 0, 0, 0, 0, 0, 1, 0, 0, 0.1f, 0};
            for (int pass = 0; pass < 2; ++pass) {
            if (pass == 1) {
                Warp::TestSetup(camV2w, camP, 0.0, 0.0005, 0.0005);
                Warp::SetEnabled(true);
            }
            FrameGen::SetEnabled(true);
            const auto before = FrameGen::Generated();
            const auto warpsBefore = Warp::Encoded();
            for (int frame = 0; frame < 12; ++frame) {
                @autoreleasepool {
                    Input::InjectRaw(CACurrentMediaTime(), 20, 5);
                    id<MTLCommandBuffer> cb = [queue commandBuffer];
                    MTLRenderPassDescriptor* uiPass = [MTLRenderPassDescriptor renderPassDescriptor];
                    uiPass.colorAttachments[0].texture = fui;
                    uiPass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    uiPass.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
                    uiPass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    [[cb renderCommandEncoderWithDescriptor:uiPass] endEncoding];
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
            usleep(100000); // the last late frame
            if (FrameGen::Generated() - before < 8) {
                std::fprintf(stderr, "generated %llu\n", FrameGen::Generated() - before);
                return Fail("frame generation produced no frames");
            }
            if (pass == 1 && Warp::Encoded() - warpsBefore < 8) {
                std::fprintf(stderr, "warps %llu\n", Warp::Encoded() - warpsBefore);
                return Fail("frame warp encoded nothing");
            }
            }
            Warp::SetEnabled(false);
        }

        // Frame warp geometry, against Metal's own rasterizer: a square drawn from a camera, re-aimed by a yaw and pitch,
        // lands where the square drawn from the turned camera is (both handednesses of view space). And the latency fit
        // finds a known latency and sensitivity.
        {
            std::vector<double> t, d;
            auto counts = [](double x) { return 1000 * std::sin(x * 3.0) + 400 * std::sin(x * 7.3); };
            for (int i = 0; i <= 120; ++i) {
                t.push_back(i * 0.0417);
            }
            for (int i = 0; i < 120; ++i) {
                d.push_back(0.0005 * (counts(t[i + 1] - 0.072) - counts(t[i] - 0.072)));
            }
            double lat = 0, k = 0, r2 = 0;
            if (!Warp::FitLatency(t, d, counts, lat, k, r2) || std::abs(lat - 0.072) > 0.003 ||
                std::abs(k - 0.0005) > 1e-5 || r2 < 0.99) {
                std::fprintf(stderr, "fit latency %.4f k %.6f r2 %.3f\n", lat, k, r2);
                return Fail("frame warp latency fit");
            }

            static const char* squareSource = R"(
#include <metal_stdlib>
using namespace metal;
vertex float4 sq_vs(uint id [[vertex_id]], constant float4* pts [[buffer(0)]], constant float4x4& vp [[buffer(1)]])
{ return vp * pts[id]; }
fragment float4 sq_fs() { return float4(1.0); }
)";
            NSError* sqErr = nil;
            id<MTLLibrary> sqLib = [dev newLibraryWithSource:@(squareSource) options:nil error:&sqErr];
            MTLRenderPipelineDescriptor* rpd = [[MTLRenderPipelineDescriptor new] autorelease];
            rpd.vertexFunction = [sqLib newFunctionWithName:@"sq_vs"];
            rpd.fragmentFunction = [sqLib newFunctionWithName:@"sq_fs"];
            rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
            id<MTLRenderPipelineState> sq = [dev newRenderPipelineStateWithDescriptor:rpd error:&sqErr];
            if (!sq) {
                return Fail("square pipeline");
            }
            const int W = 256, H = 128;
            MTLTextureDescriptor* wd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                          width:W
                                                                                         height:H
                                                                                      mipmapped:NO];
            wd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            id<MTLTexture> src = [dev newTextureWithDescriptor:wd], ref = [dev newTextureWithDescriptor:wd],
                           out = [dev newTextureWithDescriptor:wd];
            const simd_float4x4 P = {{{0.866f, 0, 0, 0}, {0, 1.732f, 0, 0}, {0, 0, 0, 1}, {0, 0, 0.1f, 0}}};
            auto draw = [&](id<MTLCommandBuffer> cb, id<MTLTexture> target, simd_float3x3 R, const simd_float4* pts) {
                const simd_float3x3 Rt = simd_transpose(R);
                const simd_float4x4 view = {{simd_make_float4(Rt.columns[0], 0), simd_make_float4(Rt.columns[1], 0),
                                             simd_make_float4(Rt.columns[2], 0), {0, 0, 0, 1}}};
                const simd_float4x4 vp = simd_mul(P, view);
                MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = target;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:sq];
                [re setVertexBytes:pts length:6 * sizeof(simd_float4) atIndex:0];
                [re setVertexBytes:&vp length:sizeof(vp) atIndex:1];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [re endEncoding];
            };
            id<MTLBuffer> rb = [dev newBufferWithLength:W * H * 8 options:MTLResourceStorageModeShared];
            auto centroid = [&](id<MTLTexture> tex, double& cx, double& cy) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
                [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(W, H, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 8
                    destinationBytesPerImage:W * H * 8];
                [b endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                const __fp16* px = static_cast<const __fp16*>(rb.contents);
                double sum = 0;
                cx = cy = 0;
                for (int y = 0; y < H; ++y) {
                    for (int x = 0; x < W; ++x) {
                        const double v = px[(y * W + x) * 4];
                        sum += v;
                        cx += v * (x + 0.5);
                        cy += v * (y + 0.5);
                    }
                }
                cx /= std::max(sum, 1e-9);
                cy /= std::max(sum, 1e-9);
                return sum > 1;
            };
            for (int hand = 0; hand < 2; ++hand) {
                // View x right, y up, z forward; world z up, forward +x.
                const simd_float3 fwd = {1, 0, 0}, up = {0, 0, 1}, right = {0, hand ? -1.0f : 1.0f, 0};
                const simd_float3x3 R = simd_matrix(right, up, fwd);
                const simd_float3 c = fwd * 10 + right * 1.0f + up * 0.5f;
                const simd_float4 pts[6] = {simd_make_float4(c - right * 0.3f - up * 0.3f, 1),
                                            simd_make_float4(c + right * 0.3f - up * 0.3f, 1),
                                            simd_make_float4(c + right * 0.3f + up * 0.3f, 1),
                                            simd_make_float4(c - right * 0.3f - up * 0.3f, 1),
                                            simd_make_float4(c + right * 0.3f + up * 0.3f, 1),
                                            simd_make_float4(c - right * 0.3f + up * 0.3f, 1)};
                const double yaw = 0.06, pitch = 0.04;
                // The turned camera as Warp builds it: yaw about world z, pitch about the camera's right axis with the
                // sign that raises asin(forward.z).
                auto rot = [](simd_float3 axis, float a) { return simd_matrix3x3(simd_quaternion(a, axis)); };
                const double raise = std::asin(simd_mul(rot(right, 1e-3f), fwd).z) - std::asin(fwd.z);
                const simd_float3x3 A = simd_mul(rot(simd_make_float3(0, 0, 1), yaw),
                                                 rot(right, (raise < 0 ? -1.0f : 1.0f) * static_cast<float>(pitch)));
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                draw(cb, src, R, pts);
                draw(cb, ref, simd_mul(A, R), pts);
                float r9[9], p16[16];
                std::memcpy(r9, &R.columns[0], 12);
                std::memcpy(r9 + 3, &R.columns[1], 12);
                std::memcpy(r9 + 6, &R.columns[2], 12);
                std::memcpy(p16, &P, 64);
                Warp::EncodeWith(cb, src, nil, nil, out, r9, p16, yaw, pitch);
                [cb commit];
                [cb waitUntilCompleted];
                double sx, sy, rx, ry, ox, oy;
                if (!centroid(src, sx, sy) || !centroid(ref, rx, ry) || !centroid(out, ox, oy)) {
                    return Fail("frame warp: square not drawn");
                }
                std::fprintf(stderr, "warp (%s view): square at %.1f,%.1f; turned camera %.1f,%.1f; re-aimed %.1f,%.1f\n",
                             hand ? "left-handed" : "right-handed", sx, sy, rx, ry, ox, oy);
                if (std::hypot(ox - rx, oy - ry) > 1.0 || std::hypot(sx - rx, sy - ry) < 5.0) {
                    return Fail("frame warp geometry");
                }
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
