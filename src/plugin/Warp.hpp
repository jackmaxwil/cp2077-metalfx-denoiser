#pragma once

#include <cstddef>
#include <functional>
#include <vector>

// Frame warp (Warp.mm): re-aims a finished frame to the camera the newest mouse input gives, just before it is shown,
// so turning shows up without waiting for the game to render it (the idea of NVIDIA Reflex 2's Frame Warp). Rotation
// only: the frame's camera (NRD's gViewToWorld and projection, Denoise.mm) is turned by the yaw and pitch that the mouse
// movement since the frame's input read adds; the edges the turn reveals repeat the frame's border pixels, and the HUD
// stays where the game drew it.
//
// Calibration, live: per presented frame, the camera's yaw and pitch change against the raw mouse movement (Input.mm)
// over the same interval shifted back by a latency L; the L that fits best (least squares, no intercept) is the time
// from moving the mouse to the game presenting a frame that shows it, and the fit's slope is the game's sensitivity.
// Warp runs only while the fit is good (gameplay; not menus, vehicles' scripted cameras or cutscenes).
namespace Warp {

void SetEnabled(bool on);
bool Enabled();
// Warps encoded since start.
unsigned long long Encoded();

// Best latency (seconds) in [0, 0.25] for frames at times t with angle changes d (frame i - 1 to i) against movement
// counts(time); k is the slope (angle per count) and r2 the fit; false without enough movement.
bool FitLatency(const std::vector<double>& t, const std::vector<double>& d, const std::function<double(double)>& counts,
                double& latency, double& k, double& r2);

#ifdef __OBJC__ // MetalTrace / FrameGen; plain C++ (main.cpp, with RED4ext's Windows BOOL) sees only the above
} // namespace Warp
#include <objc/objc.h>
namespace Warp {

// The game presents a new frame (FrameGen::Present, host time t): samples its camera for the calibration; logs the
// input lag numbers about every ten seconds.
void FramePresented(double t);
// A frame presented (by the game's present call) at host time call was shown at host time shown.
void FrameShown(double call, double shown);

// Enabled, calibrated, camera live.
bool Ready();

// Encodes into dst (output size, shader write): src re-aimed to the camera of the newest mouse input. src's camera is
// the latest frame's plus phase times its last change (-0.5: halfway from the previous frame, a generated frame). cur
// (HUD source) and ui (the game's HUD layer, alpha as mask; nil for none) keep the HUD in place. False when nothing was
// encoded (not ready, or no turn to apply).
bool Encode(id commandBuffer, id src, id cur, id ui, id dst, double phase);

// Tests: frames take this camera (view to world and view to clip, 4x4 column-major) instead of NRD's, and the
// calibration is set (latency in seconds, radians per count).
void TestSetup(const float viewToWorld[16], const float viewToClip[16], double latency, double kx, double ky);
// Tests: the same kernel with an explicit view to world rotation (3x3, column-major), view to clip matrix (4x4,
// column-major) and a turn in radians.
bool EncodeWith(id commandBuffer, id src, id cur, id ui, id dst, const float viewToWorld[9], const float viewToClip[16],
                double yaw, double pitch);
#endif

} // namespace Warp
