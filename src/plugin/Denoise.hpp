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

// MetalFX measures the exposure itself (request "denoiseexposure auto|game"); recreates the denoised scaler.
void SetAutoExposure(bool on);
// Specular hit distance for the denoised scaler from RELAX's noisy specular alpha (-1 off; path tracing: which of its
// two textures). Request "denoisehit off|0|1".
void SetHitDistance(int index);
// MetalFX's reactive mask from the transparencies (Denoise.mm): request "denoisereactive on|off|save".
void SetReactive(const std::string& how);
// Camera matrices given to the denoised scaler: "game" (NRD's), "identity", or "rh" (NRD's, view space flipped to -z).
bool SetCameraMode(const std::string& mode);
// Read the camera even when off (motion tests).
void SetWatch(bool on);
// Sharpening after the denoised scaler (RCAS, contrast adaptive): 0 off, 1 strongest. The game's own sharpening runs in
// its MetalFX path, which the denoised scaler replaces.
void SetSharpness(float amount);
bool Active();
// The encoder hooks feed Denoise: while active, and while frame generation needs the game's HUD composite found.
bool Hooked();
// The next denoised scaler call's inputs (color and guides) as PNGs in the trace folder (dsin-*). Request "denoiseinputs".
void SaveInputs();
// RELAX pass-through pairing: 0 binding slots (default), 1 slots reversed, 2 object address. Request "denoisepair".
void SetPairOrder(int order);
// The projection of the latest ray traced frame (from NRD's constants): vertical field of view in degrees, near plane,
// aspect ratio; false before the first.
bool Projection(float& fovY, float& nearPlane, float& aspect);
// The camera of the latest ray traced frame (NRD's gCameraDelta and gViewToWorld); false before the first.
bool Camera(float delta[4], float viewToWorld[16], uint64_t& serial);
// The latest ray traced frame's view to clip matrix (column-major, NRD's gWorldToClip times gViewToWorld).
bool ViewToClip(float m[16]);

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
// Reactive mask (transparencies): before the game creates a render encoder on commandBuffer for desc, and after an
// encoder's endEncoding.
void BeforeRenderPass(id commandBuffer, id desc);
void NoteRenderEncoder(id encoder); // the encoder the game got for that pass
void AfterEndEncoding(id encoder);
// Before the game makes any other encoder on commandBuffer, or commits it.
void BeforeEncoder(id commandBuffer);
// The reactive mask the denoised scaler got in the scaler call just encoded (render size, R8Unorm); nil if none.
id ReactiveMask();

// The game's MetalFX temporal scaler encode (once per frame); true when the denoised scaler was encoded instead.
bool EncodeScaler(id scaler, id commandBuffer);
#endif

} // namespace Denoise
