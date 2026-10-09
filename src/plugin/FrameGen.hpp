#pragma once

#include <functional>

// MetalFX frame interpolation (FrameGen.mm), driven from MetalTrace's hooks.
namespace FrameGen {

void SetEnabled(bool on);
bool Enabled();
// Hold of the game's frame after the generated one: half the frame interval (true), or that rounded down to whole
// display refreshes (false, the default). Request "fghold half|floor".
void SetHoldHalf(bool on);
// Request "warpdump <n>": the next n re-aimed game frames as PNGs with the game's next frame (wd<i>-src, -warp, -next).
void WarpDump(int frames);
// Generated frames presented since start.
unsigned long long Generated();
// Quality check (request "fgeval <n>", during a steady camera turn): the next n samples, every third frame, interpolate
// between frames N-2 and N (frame N's motion doubled) and save the result next to the real frame N-1 as PNGs
// (fgeval<i>-gen-u<0|1>, -real, -prev2, -cur; u1: with the HUD layer as UI texture, u0: without, alternating), after three
// samples of the normal path (fgnormal<i>-gen, -prev, -cur).
void Evaluate(int samples);

#ifdef __OBJC__ // the hooks (MetalTrace.mm); plain C++ (main.cpp, with RED4ext's Windows BOOL) sees only the above
} // namespace FrameGen
#include <objc/objc.h>
namespace FrameGen {

// After the game's MetalFX temporal scaler encode (either scaler): copies this frame's depth and motion.
void AfterScaler(id scaler, id commandBuffer);

// Every render pass the game begins (desc: MTLRenderPassDescriptor): notes the output-size RGBA8 sRGB color targets
// (the UI layers), the candidates for the interpolator's UI texture.
void RenderPass(id desc);

// The game presents drawable on commandBuffer. present(drawable) and presentAfter(drawable, seconds) call the original
// presentDrawable: / presentDrawable:afterMinimumDuration: on that command buffer. Returns true when it presented
// (a generated frame, then the game's), false when the caller should present as usual.
bool Present(id commandBuffer, id drawable, const std::function<void(id)>& present,
             const std::function<void(id, double)>& presentAfter);
#endif

} // namespace FrameGen
