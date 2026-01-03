/**
 * @file main.cpp
 * @brief MetalFX Denoiser RED4ext plugin entry point
 * 
 * This plugin replaces NRD (NVIDIA Real-time Denoisers) with Apple's
 * MetalFX Temporal Scaler for improved ray tracing performance on macOS.
 */

#include <RED4ext/RED4ext.hpp>
#include <iostream>

#include "NRDHooks.hpp"
#include "../framework/MetalBridge.h"

// Global context
static MetalFXContext* g_metalFXContext = nullptr;
static bool g_initialized = false;

namespace MetalFXDenoiser {

/**
 * Initialize the MetalFX denoiser system
 */
bool Initialize() {
    if (g_initialized) {
        std::cerr << "[MetalFXDenoiser] Already initialized" << std::endl;
        return true;
    }
    
    std::cerr << "[MetalFXDenoiser] Initializing MetalFX Denoiser v1.0.0" << std::endl;
    
    // Check MetalFX support
    if (!MetalFX_IsSupported()) {
        std::cerr << "[MetalFXDenoiser] ERROR: MetalFX not supported on this system" << std::endl;
        return false;
    }
    
    // Create MetalFX context (will use game's Metal device if hooked)
    g_metalFXContext = MetalFX_CreateContext(nullptr);
    if (!g_metalFXContext) {
        std::cerr << "[MetalFXDenoiser] ERROR: Failed to create MetalFX context" << std::endl;
        return false;
    }
    
    std::cerr << "[MetalFXDenoiser] MetalFX context created successfully" << std::endl;
    
    // Attach NRD hooks
    if (!NRDHooks::Initialize(g_metalFXContext)) {
        std::cerr << "[MetalFXDenoiser] ERROR: Failed to attach NRD hooks" << std::endl;
        MetalFX_DestroyContext(g_metalFXContext);
        g_metalFXContext = nullptr;
        return false;
    }
    
    std::cerr << "[MetalFXDenoiser] NRD hooks attached successfully" << std::endl;
    
    g_initialized = true;
    std::cerr << "[MetalFXDenoiser] Initialization complete" << std::endl;
    
    return true;
}

/**
 * Shutdown the MetalFX denoiser system
 */
void Shutdown() {
    if (!g_initialized) {
        return;
    }
    
    std::cerr << "[MetalFXDenoiser] Shutting down..." << std::endl;
    
    // Detach hooks first
    NRDHooks::Shutdown();
    
    // Destroy MetalFX context
    if (g_metalFXContext) {
        MetalFX_DestroyContext(g_metalFXContext);
        g_metalFXContext = nullptr;
    }
    
    g_initialized = false;
    std::cerr << "[MetalFXDenoiser] Shutdown complete" << std::endl;
}

/**
 * Get the MetalFX context
 */
MetalFXContext* GetContext() {
    return g_metalFXContext;
}

} // namespace MetalFXDenoiser

// =============================================================================
// RED4ext Plugin Interface
// =============================================================================

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(
    RED4ext::PluginHandle aHandle,
    RED4ext::EMainReason aReason,
    const RED4ext::Sdk* aSdk)
{
    switch (aReason) {
    case RED4ext::EMainReason::Load:
        return MetalFXDenoiser::Initialize();
        
    case RED4ext::EMainReason::Unload:
        MetalFXDenoiser::Shutdown();
        return true;
    }
    
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::PluginInfo* aInfo) {
    aInfo->name = L"MetalFX Denoiser";
    aInfo->author = L"Cyberpunk 2077 macOS Modding Community";
    aInfo->version = RED4EXT_SEMVER(1, 0, 0);
    aInfo->runtime = RED4EXT_RUNTIME_LATEST;
    aInfo->sdk = RED4EXT_SDK_LATEST;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports() {
    return RED4EXT_API_VERSION_LATEST;
}
