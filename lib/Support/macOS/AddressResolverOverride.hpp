#pragma once

/**
 * @file AddressResolverOverride.hpp
 * @brief NRD function address mappings for MetalFX Denoiser mod
 * 
 * This file contains macOS ARM64 addresses for NRD denoiser functions
 * in Cyberpunk 2077 v2.21.
 * 
 * IMPORTANT: These addresses change with game updates!
 * Run scripts/discover_nrd_addresses.py to regenerate.
 */

#include <cstdint>

namespace NRD {
namespace Address {

// Game version this was generated for
constexpr const char* GAME_VERSION = "2.21";

// =============================================================================
// REBLUR Denoiser Functions
// =============================================================================

// Main REBLUR diffuse denoiser function
// Handles: Temporal accumulation, blur, post-blur for diffuse channel
constexpr uintptr_t REBLUR_Diffuse = 0xF5A408;

// Main REBLUR diffuse+specular combined denoiser
// Handles: Both channels with shared temporal data
constexpr uintptr_t REBLUR_DiffuseSpecular = 0xF6AFA0;

// =============================================================================
// SIGMA Shadow Denoiser
// =============================================================================

// Shadow filtering entry point
constexpr uintptr_t SIGMA_Shadow = 0xF7901C;

// =============================================================================
// NRD Configuration & Memory
// =============================================================================

// NRD inputs configuration
constexpr uintptr_t NrdInputs = 0xFEF864;

// NRD memory management (from symbols)
constexpr uintptr_t NrdAllocate = 0xFA7B7C;
constexpr uintptr_t NrdReallocate = 0xFA7BCC;
constexpr uintptr_t NrdFree = 0xFA7C40;

// =============================================================================
// Render Node Entry Points
// =============================================================================

// Ray tracing filter output node (shared by multiple filters)
constexpr uintptr_t FilterOutput = 0xFEDE44;

// =============================================================================
// RTXDI Denoising
// =============================================================================

// RTXDI denoising enable/dispatch
constexpr uintptr_t RTXDI_Denoising = 0x16B9578;

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get address from offset
 * @param offset Address offset from image base
 * @return Full address with image base
 */
inline uintptr_t GetAddress(uintptr_t offset) {
    // Image base for macOS Mach-O
    constexpr uintptr_t IMAGE_BASE = 0x100000000;
    return IMAGE_BASE + offset;
}

/**
 * Validate that addresses are reasonable
 * @return true if addresses appear valid
 */
inline bool ValidateAddresses() {
    // All addresses should be in TEXT segment (roughly 0x4000 - 0x5000000)
    auto isValid = [](uintptr_t addr) {
        return addr >= 0x4000 && addr < 0x8000000;
    };
    
    return isValid(REBLUR_Diffuse) &&
           isValid(REBLUR_DiffuseSpecular) &&
           isValid(SIGMA_Shadow) &&
           isValid(NrdInputs) &&
           isValid(NrdAllocate);
}

} // namespace Address
} // namespace NRD
