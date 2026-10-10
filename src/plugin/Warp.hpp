#pragma once

#include <simd/simd.h>

#include <cstdint>

// Camera warp for 4x frame generation (Warp.mm): each frame the pacer shows is turned to the camera the game's mouse
// input gives about one rendered frame later than the frame was made with, so turning shows up a frame sooner, and as
// smoothly as the input itself (the target input advances with display time, by the mouse events' own timestamps).
// Rotation only (yaw about world up, pitch about the camera's right axis), at most 4 degrees; the HUD stays put; edges
// the turn reveals repeat border pixels. Calibrated live: the camera's turn between frames against the game's mouse
// counts between its input reads; off while the fit is poor (vehicles, scripted cameras, cutscenes, menus).
namespace Warp {

void SetEnabled(bool on);
bool Enabled();

// A game frame's camera and the input it was made with (at its present call).
struct View {
    bool ok = false;
    double read = 0;      // the present call (host time)
    double x = 0, y = 0;  // cumulative mouse counts the game had taken
    double yaw = 0, pitch = 0;
    simd_float3x3 R;      // view to world
    simd_float4x4 P;      // view to clip
};

// At the game's present call (render thread): this frame's view; updates the calibration from the previous one.
View Capture();

// The kernel's warp: P, its inverse, and M (the new view to the frame's view).
struct Params {
    simd_float4x4 P, Pinv;
    simd_float3x3 M;
};

// For a shown frame whose image is phase (0..1] of the way from prev to cur (1: the game's frame), to be shown at about
// host time shown: the turn to the input at shown minus the input lead. False when there is nothing to warp.
bool Make(const View& prev, const View& cur, double phase, double shown, Params& out);

// The game's frame of a job is about to be shown at host time shown: updates the input lead (how far behind display
// time the newest mouse event is).
void NoteReal(double shown);

} // namespace Warp
