#pragma once

// Dynamic render scale for Ultra Performance: steps the render scale between the player's ultra_scale and 3.0 to hold
// a rendered frame rate. With the game's own dynamic resolution running (MetalFX "Dynamic") the scale goes to its
// content rectangle (EngineDrs, cheap); otherwise to the upscaler's fixed scale table (ConfigVars::SetUltraScale: every
// change reallocates the render targets, about a 160 ms frame).
namespace DynamicScale {

// targetFps 0 turns it off (the scale stays at minScale, the sharpest allowed); minScale <= 0 keeps the current one.
// The caller has set the scale table to minScale.
void Configure(float targetFps, float minScale);

// Every frame the game presents (MetalTrace's present hooks).
void OnFrame();

} // namespace DynamicScale
