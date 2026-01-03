#pragma once

/**
 * @file NRDHooks.hpp
 * @brief NRD function hook declarations
 */

#include "../framework/MetalBridge.h"

namespace NRDHooks {

/**
 * Initialize NRD function hooks
 * @param ctx MetalFX context to use for denoising
 * @return true on success
 */
bool Initialize(MetalFXContext* ctx);

/**
 * Shutdown and detach all hooks
 */
void Shutdown();

/**
 * Enable or disable hooking (for A/B testing)
 * @param enabled Whether to intercept NRD calls
 */
void SetEnabled(bool enabled);

/**
 * Check if hooks are active
 */
bool IsEnabled();

/**
 * Get number of frames processed
 */
uint64_t GetFrameCount();

} // namespace NRDHooks
