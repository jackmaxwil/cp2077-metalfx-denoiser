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
#include <cstdio>

#include <mach-o/dyld.h>

namespace NRD {
namespace Address {

// Game version this was generated for
constexpr const char* GAME_VERSION = "2.21";

// =============================================================================
// REBLUR Denoiser Functions
// =============================================================================

// Main REBLUR diffuse denoiser function
// Handles: Temporal accumulation, blur, post-blur for diffuse channel
// Source: docs/nrd_addresses.json (REBLUR_Diffuse_Temporal)
constexpr uintptr_t REBLUR_Diffuse = 0xF5A408;

// Main REBLUR diffuse+specular combined denoiser
// Handles: Both channels with shared temporal data
// Source: docs/nrd_addresses.json (REBLUR_DiffuseSpecular_Temporal)
constexpr uintptr_t REBLUR_DiffuseSpecular = 0xF6AFA0;

// =============================================================================
// SIGMA Shadow Denoiser
// =============================================================================

// Shadow filtering entry point
// Source: docs/nrd_addresses.json (SIGMA_Shadow)
constexpr uintptr_t SIGMA_Shadow = 0xF7901C;

// =============================================================================
// NRD Configuration & Memory
// =============================================================================

// NRD inputs configuration
// Source: docs/nrd_addresses.json (NrdInputs)
constexpr uintptr_t NrdInputs = 0xFEF864;

// NRD memory management (from nm symbols)
// Source: docs/nrd_addresses.json (_symbols)
constexpr uintptr_t NrdAllocate = 0xFA7B7C;
constexpr uintptr_t NrdReallocate = 0xFA7BCC;
constexpr uintptr_t NrdFree = 0xFA7C40;

// =============================================================================
// Render Node Entry Points
// =============================================================================

// Ray tracing filter output node (shared by multiple filters)
// Source: docs/nrd_addresses.json (CRenderNode_RayTracingFilterOutput)
constexpr uintptr_t FilterOutput = 0xFEEAA8;

// =============================================================================
// RTXDI Denoising
// =============================================================================

// RTXDI denoising enable/dispatch
// Source: docs/nrd_addresses.json (RTXDI_Denoising_Enable)
constexpr uintptr_t RTXDI_Denoising = 0x16B9578;

// =============================================================================
// Additional Addresses (from discover_nrd_addresses.py)
// =============================================================================

// FilterRayTracedLocalShadow render node
// Source: docs/nrd_addresses.json (CRenderNode_FilterRayTracedLocalShadow)
constexpr uintptr_t FilterRayTracedLocalShadow = 0xFEE9F0;

// =============================================================================
// Address Categories
// =============================================================================

enum class AddressCategory {
    Required,   // Hook will fail if missing
    Optional,   // Warning only if missing
    Debug       // Only used for analysis
};

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get address from offset
 * @param offset Address offset from image base
 * @return Full address with image base
 */
inline uintptr_t GetAddress(uintptr_t offset) {
    // Mach-O main executable base is 0x100000000 + ASLR slide at runtime.
    constexpr uintptr_t IMAGE_BASE = 0x100000000;
    const uintptr_t slide = static_cast<uintptr_t>(_dyld_get_image_vmaddr_slide(0));
    return IMAGE_BASE + slide + offset;
}

/**
 * Validate that a discovered offset matches our constants
 * @param discovered The offset from address discovery
 * @param expected The expected offset from this header
 * @return true if they match
 */
inline bool ValidateDiscoveredOffset(uintptr_t discovered, uintptr_t expected) {
    return discovered == expected;
}

/**
 * Check if an address is in valid executable range
 */
inline bool IsValidExecutableAddress(uintptr_t addr) {
    // TEXT segment on macOS ARM64 typically 0x4000 - 0x2000000 for CP77
    return addr >= 0x4000 && addr < 0x2000000;
}

/**
 * Get category for a given address constant
 */
inline AddressCategory GetAddressCategory(uintptr_t addr) {
    if (addr == REBLUR_Diffuse ||
        addr == REBLUR_DiffuseSpecular ||
        addr == SIGMA_Shadow) {
        return AddressCategory::Required;
    }
    if (addr == NrdInputs ||
        addr == FilterOutput ||
        addr == RTXDI_Denoising) {
        return AddressCategory::Optional;
    }
    return AddressCategory::Debug;
}

/**
 * Get human-readable name for an address constant
 */
inline const char* GetAddressName(uintptr_t addr) {
    if (addr == REBLUR_Diffuse) return "REBLUR_Diffuse";
    if (addr == REBLUR_DiffuseSpecular) return "REBLUR_DiffuseSpecular";
    if (addr == SIGMA_Shadow) return "SIGMA_Shadow";
    if (addr == NrdInputs) return "NrdInputs";
    if (addr == FilterOutput) return "FilterOutput";
    if (addr == RTXDI_Denoising) return "RTXDI_Denoising";
    if (addr == FilterRayTracedLocalShadow) return "FilterRayTracedLocalShadow";
    if (addr == NrdAllocate) return "NrdAllocate";
    return "Unknown";
}

/**
 * Comprehensive address validation with detailed logging
 * @return true if all required addresses are valid
 */
inline bool ValidateAddressesDetailed(void (*logFn)(const char*) = nullptr) {
    auto log = [logFn](const char* msg) {
        if (logFn) logFn(msg);
    };
    
    bool allRequiredValid = true;
    int requiredCount = 0;
    int requiredValid = 0;
    int optionalCount = 0;
    int optionalValid = 0;
    
    // Check all address constants
    const uintptr_t addresses[] = {
        REBLUR_Diffuse, REBLUR_DiffuseSpecular, SIGMA_Shadow,
        NrdInputs, FilterOutput, RTXDI_Denoising,
        FilterRayTracedLocalShadow, NrdAllocate
    };
    
    for (uintptr_t addr : addresses) {
        bool valid = IsValidExecutableAddress(addr);
        auto cat = GetAddressCategory(addr);
        const char* name = GetAddressName(addr);
        
        if (cat == AddressCategory::Required) {
            requiredCount++;
            if (valid) requiredValid++;
            else allRequiredValid = false;
        } else if (cat == AddressCategory::Optional) {
            optionalCount++;
            if (valid) optionalValid++;
        }
    }
    
    // Log summary
    char buf[256];
    snprintf(buf, sizeof(buf), 
             "[MetalFXDenoiser] Address validation: Required %d/%d, Optional %d/%d",
             requiredValid, requiredCount, optionalValid, optionalCount);
    log(buf);
    
    if (!allRequiredValid) {
        log("[MetalFXDenoiser] ERROR: Required addresses invalid - mod will not function!");
        log("[MetalFXDenoiser] Run scripts/discover_nrd_addresses.py to update offsets");
    }
    
    return allRequiredValid;
}

/**
 * Legacy validation - checks if addresses are in reasonable range
 * @return true if addresses appear valid
 */
inline bool ValidateAddresses() {
    return ValidateAddressesDetailed(nullptr);
}

} // namespace Address
} // namespace NRD
