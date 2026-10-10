// Multi-frame generation research: can MTLFXFrameInterpolator (always a midpoint) give frames at 1/4 and 3/4?
//
//     ./build/fg_phase <dir with fgseq dumps> <plugin log>
//
// Input: a "fgseq <n>" sequence from the game (FrameGen::SaveSequence: consecutive presented frames' color, depth and
// motion as raw dumps, camera parameters in the log), taken during a steady turn. For every frame k >= 4 of it, the
// interpolator runs on frames k-4 and k (motion of k times 4) and its results are scored against the real frames
// k-3, k-2 and k-1 (PSNR over the scene, HUD margins cropped, after the dumps' tone map):
// - midpoint: k-4, k at scale 4, against k-2. Reference: the stride 2 midpoint (k-2, k at scale 2, against k-1) is
//   today's frame generation at twice the motion.
// - recursive: 3/4 from (midpoint, k) at scale 2 (k's depth and motion fit k exactly); 1/4 from (k-4, midpoint) at
//   scale 2 with k's depth and motion (they fit the midpoint only approximately).
// - scaled: k-4, k with the motion scaled as if it were half (scale 2) or a quarter: which real frame does it match?
// Baselines: the nearest real input repeated, and the linear blend of the two inputs at the phase.
// Each interpolator instance is warmed on the same call first (after a reset it returns its color input).

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Frame {
    std::string color, depth, motion; // dump paths
    uint64_t frame = 0;
    float dt = 0, mvx = 0, mvy = 0, jx = 0, jy = 0, fov = 60, nearPlane = 0.02f, aspect = 1.6f;
    bool reversed = true;
};

id<MTLDevice> g_dev;
id<MTLCommandQueue> g_queue;
NSUInteger g_ow = 0, g_oh = 0, g_iw = 0, g_ih = 0;
MTLPixelFormat g_motionFormat = MTLPixelFormatRG16Float; // the dumps' format (the game: RGBA16Float)

std::vector<char> Read(const std::string& path)
{
    std::ifstream f(path, std::ios::binary);
    return std::vector<char>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

id<MTLTexture> Texture(MTLPixelFormat f, NSUInteger w, NSUInteger h)
{
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    return [g_dev newTextureWithDescriptor:td];
}

id<MTLTexture> Load(const std::string& path, MTLPixelFormat f, NSUInteger w, NSUInteger h, size_t bpp)
{
    std::vector<char> data = Read(path);
    if (data.size() != w * h * bpp) {
        fprintf(stderr, "%s: %zu bytes, expected %zu\n", path.c_str(), data.size(), w * h * bpp);
        exit(1);
    }
    id<MTLBuffer> b = [g_dev newBufferWithBytes:data.data() length:data.size() options:MTLResourceStorageModeShared];
    id<MTLTexture> t = Texture(f, w, h);
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp
              sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return t;
}

// The scene part of an RGBA16Float output-size texture, tone mapped as the dumps' PNGs, as floats (RGB).
std::vector<float> Scene(id<MTLTexture> t)
{
    const NSUInteger row = t.width * 8;
    id<MTLBuffer> b = [g_dev newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row
         destinationBytesPerImage:row * t.height];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    const auto* p = static_cast<const __fp16*>(b.contents);
    std::vector<float> out;
    const NSUInteger y0 = t.height * 12 / 100, y1 = t.height * 80 / 100, x0 = t.width * 15 / 100, x1 = t.width * 85 / 100;
    out.reserve((y1 - y0) * (x1 - x0) * 3);
    for (NSUInteger y = y0; y < y1; ++y) {
        for (NSUInteger x = x0; x < x1; ++x) {
            for (int c = 0; c < 3; ++c) {
                float v = std::max(0.0f, static_cast<float>(p[(y * t.width + x) * 4 + c]));
                out.push_back(std::sqrt(v / (1.0f + v)));
            }
        }
    }
    return out;
}

double Psnr(const std::vector<float>& a, const std::vector<float>& b)
{
    double se = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        const double d = a[i] - b[i];
        se += d * d;
    }
    const double mse = se / a.size();
    return mse == 0 ? 99.0 : 10.0 * std::log10(1.0 / mse);
}

std::vector<float> Blend(const std::vector<float>& a, const std::vector<float>& b, float t)
{
    std::vector<float> out(a.size());
    for (size_t i = 0; i < a.size(); ++i) {
        out[i] = a[i] * (1 - t) + b[i] * t;
    }
    return out;
}

// Bilinear resize (down to the half output for interpolation, and back up).
id<MTLTexture> Resize(id<MTLTexture> src, NSUInteger w, NSUInteger h)
{
    id<MTLTexture> dst = Texture(src.pixelFormat, w, h);
    MPSImageBilinearScale* scale = [[MPSImageBilinearScale alloc] initWithDevice:g_dev];
    id<MTLCommandBuffer> cb = [g_queue commandBuffer];
    [scale encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst];
    [cb commit];
    [cb waitUntilCompleted];
    return dst;
}

NSUInteger g_fw = 0, g_fh = 0; // the interpolator's output size (half output for the half-resolution case)

id<MTLFXFrameInterpolator> Interpolator(MTLPixelFormat depthFormat)
{
    MTLFXFrameInterpolatorDescriptor* fd = [MTLFXFrameInterpolatorDescriptor new];
    fd.colorTextureFormat = MTLPixelFormatRGBA16Float;
    fd.outputTextureFormat = MTLPixelFormatRGBA16Float;
    fd.depthTextureFormat = depthFormat;
    fd.motionTextureFormat = g_motionFormat;
    fd.inputWidth = g_iw;
    fd.inputHeight = g_ih;
    fd.outputWidth = g_fw ? g_fw : g_ow;
    fd.outputHeight = g_fh ? g_fh : g_oh;
    return [fd newFrameInterpolatorWithDevice:g_dev];
}

// A persistent interpolator fed in order (as in the game: after its reset call it returns its color input, and a
// repeated call does not warm it). Each call writes a new texture.
struct Stream {
    id<MTLFXFrameInterpolator> fi;
    int calls = 0;

    id<MTLTexture> Call(id<MTLTexture> prev, id<MTLTexture> cur, id<MTLTexture> depth, id<MTLTexture> motion,
                        const Frame& f, float scale, float dtScale)
    {
        if (!fi) {
            fi = Interpolator(depth.pixelFormat);
        }
        id<MTLTexture> out = Texture(MTLPixelFormatRGBA16Float, fi.outputWidth, fi.outputHeight);
        fi.colorTexture = cur;
        fi.prevColorTexture = prev;
        fi.depthTexture = depth;
        fi.motionTexture = motion;
        fi.outputTexture = out;
        fi.motionVectorScaleX = f.mvx * scale;
        fi.motionVectorScaleY = f.mvy * scale;
        fi.jitterOffsetX = f.jx;
        fi.jitterOffsetY = f.jy;
        fi.deltaTime = f.dt * dtScale;
        fi.nearPlane = f.nearPlane;
        fi.farPlane = 20000.0f;
        fi.fieldOfView = f.fov;
        fi.aspectRatio = f.aspect;
        fi.depthReversed = f.reversed;
        fi.shouldResetHistory = calls++ == 0;
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        [fi encodeToCommandBuffer:cb];
        [cb commit];
        [cb waitUntilCompleted];
        return out;
    }
};

} // namespace

int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: fg_phase <dump dir> <plugin log>\n");
            return 2;
        }
        g_dev = MTLCreateSystemDefaultDevice();
        g_queue = [g_dev newCommandQueue];
        std::map<int, Frame> frames;
        // Dumps: <name>-NN-fgseqII-<kind>-raw-WxH-Format.bin
        const std::regex dumpRe(R"(fgseq(\d+)-(color|depth|motion)-raw-(\d+)x(\d+)-([A-Za-z0-9_]+)\.bin$)");
        for (NSString* name in [[NSFileManager defaultManager] enumeratorAtPath:@(argv[1])]) {
            std::smatch m;
            const std::string n = name.UTF8String;
            if (!std::regex_search(n, m, dumpRe)) {
                continue;
            }
            Frame& f = frames[std::stoi(m[1])];
            const std::string path = std::string(argv[1]) + "/" + n;
            const NSUInteger w = std::stoul(m[3]), h = std::stoul(m[4]);
            if (m[2] == "color") {
                f.color = path;
                g_ow = w;
                g_oh = h;
            } else if (m[2] == "depth") {
                f.depth = path;
                g_iw = w;
                g_ih = h;
            } else {
                f.motion = path;
                g_motionFormat = m[5] == "RGBA16Float" ? MTLPixelFormatRGBA16Float : MTLPixelFormatRG16Float;
            }
        }
        std::ifstream log(argv[2]);
        const std::regex logRe(R"(fgseq(\d+) frame (\d+) dt ([\d.]+) mvscale ([-\d.]+) ([-\d.]+) jitter ([-\d.]+) ([-\d.]+) fov ([\d.]+) near ([\d.]+) aspect ([\d.]+) reversed (\d))");
        for (std::string line; std::getline(log, line);) {
            std::smatch m;
            if (std::regex_search(line, m, logRe) && frames.count(std::stoi(m[1]))) {
                Frame& f = frames[std::stoi(m[1])]; // the last sequence in the log wins
                f.frame = std::stoull(m[2]);
                f.dt = std::stof(m[3]);
                f.mvx = std::stof(m[4]);
                f.mvy = std::stof(m[5]);
                f.jx = std::stof(m[6]);
                f.jy = std::stof(m[7]);
                f.fov = std::stof(m[8]);
                f.nearPlane = std::stof(m[9]);
                f.aspect = std::stof(m[10]);
                f.reversed = m[11] == "1";
            }
        }
        std::vector<Frame> seq;
        for (auto& [i, f] : frames) {
            if (f.color.empty() || f.depth.empty() || f.motion.empty() || !f.frame) {
                fprintf(stderr, "fgseq%02d incomplete\n", i);
                return 1;
            }
            if (!seq.empty() && f.frame != seq.back().frame + 1) {
                fprintf(stderr, "fgseq%02d: frame %llu after %llu (not consecutive)\n", i, (unsigned long long)f.frame,
                        (unsigned long long)seq.back().frame);
                return 1;
            }
            seq.push_back(f);
        }
        printf("%zu frames, %lux%lu from %lux%lu, mvscale %.1f %.1f\n\n", seq.size(), (unsigned long)g_ow,
               (unsigned long)g_oh, (unsigned long)g_iw, (unsigned long)g_ih, seq.empty() ? 0 : seq[0].mvx,
               seq.empty() ? 0 : seq[0].mvy);
        // Depth dumps are the depth plane only: R32 floats, loaded as Depth32Float.
        std::vector<id<MTLTexture>> color, depth, motion;
        std::vector<std::vector<float>> scene;
        for (const Frame& f : seq) {
            color.push_back(Load(f.color, MTLPixelFormatRGBA16Float, g_ow, g_oh, 8));
            depth.push_back(Load(f.depth, MTLPixelFormatDepth32Float, g_iw, g_ih, 4));
            motion.push_back(Load(f.motion, g_motionFormat, g_iw, g_ih, g_motionFormat == MTLPixelFormatRGBA16Float ? 8 : 4));
            scene.push_back(Scene(color.back()));
        }
        std::map<std::string, std::vector<double>> score;
        int passThrough = 0, outputs = 0;
        // Scored once a stream has made two calls before (the first returns its input).
        auto add = [&](const std::string& k, double v) { score[k].push_back(v); };
        auto run = [&](Stream& st, id<MTLTexture> prev, id<MTLTexture> cur, size_t k, float scale, float dtScale,
                       std::vector<float>* out) {
            const bool scored = st.calls >= 2;
            const auto g = Scene(st.Call(prev, cur, depth[k], motion[k], seq[k], scale, dtScale));
            if (scored) {
                ++outputs;
                passThrough += Psnr(g, Scene(cur)) > 60 ? 1 : 0;
            }
            *out = g;
            return scored;
        };
        // Stride 2 (today's frame generation at twice its motion): streams of even and of odd frames.
        Stream s2[2];
        for (size_t k = 2; k < seq.size(); ++k) {
            std::vector<float> g;
            if (run(s2[k % 2], color[k - 2], color[k], k, 2, 2, &g)) {
                add("stride 2 midpoint vs k-1", Psnr(g, scene[k - 1]));
                add("stride 2 repeat k vs k-1", Psnr(scene[k], scene[k - 1]));
                add("stride 2 blend vs k-1", Psnr(Blend(scene[k - 2], scene[k], 0.5f), scene[k - 1]));
            }
        }
        // The same at half output: color down to half, interpolated there, back up (bilinear).
        {
            std::vector<id<MTLTexture>> half;
            for (id<MTLTexture> c : color) {
                half.push_back(Resize(c, g_ow / 2, g_oh / 2));
            }
            g_fw = g_ow / 2;
            g_fh = g_oh / 2;
            Stream h2[2];
            struct Half {
                Stream mid, q3, q1;
            } h4[4];
            for (size_t k = 2; k < seq.size(); ++k) {
                Stream& st = h2[k % 2];
                const bool scored = st.calls >= 2;
                id<MTLTexture> g = st.Call(half[k - 2], half[k], depth[k], motion[k], seq[k], 2, 2);
                if (scored) {
                    add("half output: stride 2 midpoint vs k-1", Psnr(Scene(Resize(g, g_ow, g_oh)), scene[k - 1]));
                    add("half output: frame k-1 down and up (resize loss alone)",
                        Psnr(Scene(Resize(half[k - 1], g_ow, g_oh)), scene[k - 1]));
                }
                if (k < 4) {
                    continue;
                }
                Half& m = h4[k % 4];
                const bool s4 = m.mid.calls >= 2;
                id<MTLTexture> mid = m.mid.Call(half[k - 4], half[k], depth[k], motion[k], seq[k], 4, 4);
                id<MTLTexture> q3 = m.q3.Call(mid, half[k], depth[k], motion[k], seq[k], 2, 2);
                id<MTLTexture> q1 = m.q1.Call(half[k - 4], mid, depth[k], motion[k], seq[k], 2, 2);
                if (s4) {
                    add("half output: 1/2 midpoint", Psnr(Scene(Resize(mid, g_ow, g_oh)), scene[k - 2]));
                    add("half output: 3/4 recursive", Psnr(Scene(Resize(q3, g_ow, g_oh)), scene[k - 1]));
                    add("half output: 1/4 recursive", Psnr(Scene(Resize(q1, g_ow, g_oh)), scene[k - 3]));
                }
            }
            g_fw = g_fh = 0;
        }
        // Stride 4: four streams (k mod 4), each with its own interpolators per method.
        struct Methods {
            Stream mid, q3, q1, x2, x1;
        } m4[4];
        for (size_t k = 4; k < seq.size(); ++k) {
            Methods& m = m4[k % 4];
            const auto& r1 = scene[k - 3];
            const auto& r2 = scene[k - 2];
            const auto& r3 = scene[k - 1];
            std::vector<float> g;
            const bool scored = m.mid.calls >= 2;
            id<MTLTexture> mid = m.mid.Call(color[k - 4], color[k], depth[k], motion[k], seq[k], 4, 4);
            if (scored) {
                add("1/2 midpoint", Psnr(Scene(mid), r2));
            }
            if (run(m.q3, mid, color[k], k, 2, 2, &g)) {
                add("3/4 recursive (mid, k)", Psnr(g, r3));
            }
            if (run(m.q1, color[k - 4], mid, k, 2, 2, &g)) {
                add("1/4 recursive (k-4, mid)", Psnr(g, r1));
            }
            for (float sc : {2.0f, 1.0f}) {
                if (run(sc == 2 ? m.x2 : m.x1, color[k - 4], color[k], k, sc, 4, &g)) {
                    char name[64];
                    std::snprintf(name, sizeof(name), "scaled x%.0f vs ", sc);
                    add(std::string(name) + "k-3", Psnr(g, r1));
                    add(std::string(name) + "k-2", Psnr(g, r2));
                    add(std::string(name) + "k-1", Psnr(g, r3));
                }
            }
            if (scored) {
                add("repeat nearest: 1/4 (k-4)", Psnr(scene[k - 4], r1));
                add("repeat nearest: 1/2 (k)", Psnr(scene[k], r2));
                add("repeat nearest: 3/4 (k)", Psnr(scene[k], r3));
                add("blend: 1/4", Psnr(Blend(scene[k - 4], scene[k], 0.25f), r1));
                add("blend: 1/2", Psnr(Blend(scene[k - 4], scene[k], 0.5f), r2));
                add("blend: 3/4", Psnr(Blend(scene[k - 4], scene[k], 0.75f), r3));
            }
            fprintf(stderr, "k=%zu done\n", k);
        }
        printf("%d of %d scored outputs are their color input (pass-through)\n\n", passThrough, outputs);
        printf("| Case | PSNR dB (mean) | min | n |\n| --- | ---: | ---: | ---: |\n");
        for (auto& [k, v] : score) {
            double sum = 0, mn = 1e9;
            for (double x : v) {
                sum += x;
                mn = std::min(mn, x);
            }
            printf("| %s | %.2f | %.2f | %zu |\n", k.c_str(), sum / v.size(), mn, v.size());
        }
    }
    return 0;
}
