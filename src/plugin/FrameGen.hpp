#pragma once

#include <functional>

// MetalFX frame interpolation (FrameGen.mm), driven from MetalTrace's hooks.
namespace FrameGen {

void SetEnabled(bool on);
bool Enabled();
// Displayed frames per rendered frame: 2 (one generated), or 4 (three generated, at half size; presented by a pacer
// thread). Config frame_generation_multiplier, request "fgmult <2|4>", METALFX_FG_MULT=4.
void SetMultiplier(int frames);
int Multiplier();
// Generated frames presented since start.
unsigned long long Generated();
// Quality check (request "fgeval <n>", during a steady camera turn): the next n samples, every third frame, interpolate
// between frames N-2 and N (frame N's motion doubled) and save the result next to the real frame N-1 as PNGs
// (fgeval<i>-gen-u<0|1>, -real, -prev2, -cur; u1: with the HUD layer as UI texture, u0: without, alternating), after three
// samples of the normal path (fgnormal<i>-gen, -prev, -cur).
void Evaluate(int samples);
// Research (request "fgseq <n>"): the next n presented frames' color, depth and motion as raw dumps (fgseq<i>-color-raw,
// -depth-raw, -motion-raw) with their camera parameters logged, for tests/fg_phase.mm.
void SaveSequence(int frames);

#ifdef __OBJC__ // the hooks (MetalTrace.mm); plain C++ (main.cpp, with RED4ext's Windows BOOL) sees only the above
} // namespace FrameGen
#include <objc/objc.h>
namespace FrameGen {

// Tests: paint the HUD restore's area (magenta) and the rest (green) on generated frames; the last generated frame
// with the HUD restored.
void SetHudDebug(bool on);
id LastGenerated();

// The game's HUD composite (Denoise.mm finds it: compute pipeline 3959251910, m_hud_occupiedTiles) ends in encoder,
// still open: snapshots the UI layer's alpha there for the HUD restore.
void HudComposite(id encoder);

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
