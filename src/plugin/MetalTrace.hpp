#pragma once

// In-process tracing of Metal compute encoding via Objective-C method swizzling.
// Logs each distinct compute pipeline state the game binds, the first step toward
// identifying the denoiser PSOs by their binding signatures (docs/PIPELINE_TRACE_FINDINGS.md).
namespace MetalTrace {

// Swizzles -[<concrete MTLComputeCommandEncoder> setComputePipelineState:]. Returns false if it could not.
bool Install();

// Restores the original implementation.
void Uninstall();

} // namespace MetalTrace
