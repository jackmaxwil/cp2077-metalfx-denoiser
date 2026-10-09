#pragma once

#include <functional>

// MetalFX frame interpolation (FrameGen.mm), driven from MetalTrace's hooks.
namespace FrameGen {

void SetEnabled(bool on);
bool Enabled();
// Generated frames presented since start.
unsigned long long Generated();

#ifdef __OBJC__ // the hooks (MetalTrace.mm); plain C++ (main.cpp, with RED4ext's Windows BOOL) sees only the above
} // namespace FrameGen
#include <objc/objc.h>
namespace FrameGen {

// After the game's MetalFX temporal scaler encode (either scaler): copies this frame's depth and motion.
void AfterScaler(id scaler, id commandBuffer);

// The game presents drawable on commandBuffer. present(drawable) and presentAfter(drawable, seconds) call the original
// presentDrawable: / presentDrawable:afterMinimumDuration: on that command buffer. Returns true when it presented
// (a generated frame, then the game's), false when the caller should present as usual.
bool Present(id commandBuffer, id drawable, const std::function<void(id)>& present,
             const std::function<void(id, double)>& presentAfter);
#endif

} // namespace FrameGen
