#pragma once

// Dynamic render scale for Ultra Performance: steps the upscaler's scale (ConfigVars::SetUltraScale) between the
// player's ultra_scale and 3.0 to hold a rendered frame rate. The game's own dynamic resolution stops at 50% (2x).
namespace DynamicScale {

// targetFps 0 turns it off (the scale stays at minScale, the sharpest allowed); minScale <= 0 keeps the current one.
// The caller has set the scale table to minScale.
void Configure(float targetFps, float minScale);

// Every frame the game presents (MetalTrace's present hooks).
void OnFrame();

} // namespace DynamicScale
