#pragma once

#include <objc/objc.h>

#include <cstddef>
#include <string>

// Path tracing denoiser prototype (Denoise.mm), driven from MetalTrace's hooks.
namespace Denoise {

// "off", "pass" (NRD RELAX pass-through: noisy lighting reaches the composite) or "fx" (pass, plus MetalFX's temporal
// denoised scaler in place of the game's temporal scaler). Returns false for an unknown mode.
bool SetMode(const std::string& mode);
bool Active();

// Compute encoders.
void BindPipeline(id encoder, const std::string& label);
void Use(id encoder, const void* const* resources, size_t count, unsigned long usage);
bool Dispatch(id encoder); // true: drop this dispatch
void EndEncoding(id encoder); // before the game's endEncoding

// Render passes (G-buffer); desc is an MTLRenderPassDescriptor.
void RenderPass(id desc);

// The game's MetalFX temporal scaler encode; true when the denoised scaler was encoded instead.
bool EncodeScaler(id scaler, id commandBuffer);

} // namespace Denoise
