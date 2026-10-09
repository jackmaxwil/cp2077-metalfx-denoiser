#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>

// In-process tracing of Metal compute encoding via Objective-C method swizzling.
// Logs each distinct compute pipeline state the game binds, the first step toward
// identifying the denoiser PSOs by their binding signatures (docs/PIPELINE_TRACE_FINDINGS.md).
namespace MetalTrace {

// Swizzles -[<concrete MTLComputeCommandEncoder> setComputePipelineState:]. Returns false if it could not.
bool Install();

// Restores the original implementation.
void Uninstall();

// Runs fn at the first presented frame (before the cvar-startup.txt settings), on the presenting thread.
void OnFirstFrame(std::function<void()> fn);

// A 120-frame timing window every everyFrames frames, logged as one "Perf play-<frame>" line (0: off; the
// METALFX_PERF_EVERY environment variable wins).
void LogPerformance(uint64_t everyFrames);

// The CPU address of a GPU address inside one of the game's large shared heap buffers (registered at creation), if
// len bytes from there are inside it; nullptr otherwise.
const uint8_t* MapGpuAddress(uint64_t gpuAddress, size_t len);

} // namespace MetalTrace
