#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

// Ray traced denoiser (Denoise.mm), driven from MetalTrace's hooks.
namespace Denoise {

// "off", "pass" (NRD RELAX pass-through: noisy lighting reaches the composite) or "fx" (pass, plus MetalFX's temporal
// denoised scaler in place of the game's temporal scaler). Returns false for an unknown mode.
bool SetMode(const std::string& mode);
// MetalFX's temporal denoised scaler exists on this Mac (macOS 26, supported GPU).
bool Supported();
// Path tracing: keep RELAX's PrePass (spatial pre-blur; default) or hand the denoiser the raw signal.
bool SetPrepass(bool on);
// Camera matrices given to the denoised scaler: "game" (NRD's), "identity", or "rh" (NRD's, view space flipped to -z).
bool SetCameraMode(const std::string& mode);
// Read the camera even when off (motion tests).
void SetWatch(bool on);
bool Active();
// The projection of the latest ray traced frame (from NRD's constants): vertical field of view in degrees, near plane,
// aspect ratio; false before the first.
bool Projection(float& fovY, float& nearPlane, float& aspect);
// The camera of the latest ray traced frame (NRD's gCameraDelta and gViewToWorld); false before the first.
bool Camera(float delta[4], float viewToWorld[16], uint64_t& serial);

#ifdef __OBJC__ // the hooks (MetalTrace.mm); plain C++ (main.cpp, with RED4ext's Windows BOOL) sees only the above
} // namespace Denoise
#include <objc/objc.h>
namespace Denoise {

// Compute encoders.
void BindPipeline(id encoder, const std::string& label);
void SetRoot(id encoder, id buffer, unsigned long offset, bool offsetOnly); // buffer index 2
void Use(id encoder, const void* const* resources, size_t count, unsigned long usage);
bool Dispatch(id encoder); // true: drop this dispatch
void EndEncoding(id encoder); // before the game's endEncoding

// Render passes (G-buffer); desc is an MTLRenderPassDescriptor.
void RenderPass(id desc);

// The game's MetalFX temporal scaler encode (once per frame); true when the denoised scaler was encoded instead.
bool EncodeScaler(id scaler, id commandBuffer);
#endif

} // namespace Denoise
