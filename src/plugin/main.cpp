/**
 * @file main.cpp
 * @brief MetalFX Denoiser RED4ext plugin entry point
 * 
 * This plugin replaces NRD (NVIDIA Real-time Denoisers) with Apple's
 * MetalFX Temporal Scaler for improved ray tracing performance on macOS.
 */

#include <RED4ext/RED4ext.hpp>
#include <iostream>
#include <sstream>

#include "NRDHooks.hpp"
#include "Config.hpp"
#include "Logger.hpp"
#include "MetalBridge.h"
#include "Support/macOS/AddressResolverOverride.hpp"

// Forward declaration for Frida integration
extern void FridaIntegration_Init(MetalFXContext* ctx);
extern void FridaIntegration_Shutdown();

// Global context
static MetalFXContext* g_metalFXContext = nullptr;
static bool g_initialized = false;

namespace MetalFXDenoiser {

/**
 * Logging helper for address validation
 */
static void ValidationLog(const char* msg) {
    Logger::Info(msg ? msg : "");
}

/**
 * Initialize the MetalFX denoiser system
 */
bool Initialize() {
    if (g_initialized) {
        Logger::Info("Already initialized");
        return true;
    }
    
    Logger::Initialize();
    Logger::Info("Initializing MetalFX Denoiser v1.0.0");
    Logger::Info(std::string("Target game version: ") + NRD::Address::GAME_VERSION);
    
    // Validate addresses before proceeding
    Logger::Info("Validating NRD addresses...");
    if (!NRD::Address::ValidateAddressesDetailed(ValidationLog)) {
        Logger::Error("Address validation failed");
        Logger::Error("This mod version is incompatible with your game version");
        Logger::Error("Please check for mod updates or run address discovery");
        return false;  // Fail-fast: don't load if addresses are wrong
    }
    Logger::Info("Address validation passed");
    
    // Load configuration
    Config::Load();
    const auto& config = Config::Get();
    
    {
        std::ostringstream os;
        os << "Config loaded: enabled=" << (config.enabled ? "yes" : "no")
           << " shadows=" << (config.features.shadows ? "yes" : "no")
           << " rtxdiDiffuse=" << (config.features.rtxdiDiffuse ? "yes" : "no")
           << " rtxdiSpecular=" << (config.features.rtxdiSpecular ? "yes" : "no")
           << " gi=" << (config.features.restirGI ? "yes" : "no")
           << " reflections=" << (config.features.reflections ? "yes" : "no")
           << " ao=" << (config.features.ao ? "yes" : "no");
        Logger::Info(os.str());
    }
    
    if (!config.enabled) {
        Logger::Warn("Plugin disabled in config");
        return true;  // Return true to keep loaded but inactive
    }
    
    // Check MetalFX support
    if (!MetalFX_IsSupported()) {
        Logger::Error("MetalFX not supported on this system");
        Logger::Error("Requires macOS 13+ on Apple Silicon");
        return false;
    }
    
    // Create MetalFX context (will use game's Metal device if hooked)
    g_metalFXContext = MetalFX_CreateContext(nullptr);
    if (!g_metalFXContext) {
        Logger::Error("Failed to create MetalFX context");
        return false;
    }
    
    Logger::Info("MetalFX context created successfully");
    
    // Initialize Frida integration (for external hook calls)
    FridaIntegration_Init(g_metalFXContext);
    Logger::Info("Frida integration initialized");
    
    // Attach NRD hooks
    if (!NRDHooks::Initialize(g_metalFXContext)) {
        Logger::Warn("Failed to attach NRD hooks");
        Logger::Warn("Use Frida script for hook injection instead");
        // Don't fail - Frida hooks will handle this
    } else {
        Logger::Info("NRD hooks attached successfully");
    }
    
    g_initialized = true;
    Logger::Info("Initialization complete");
    Logger::Info("To enable hooks, run: frida -l metalfx_hooks.js -p <pid>");
    
    return true;
}

/**
 * Shutdown the MetalFX denoiser system
 */
void Shutdown() {
    if (!g_initialized) {
        return;
    }
    
    Logger::Info("Shutting down...");
    
    // Detach hooks first
    NRDHooks::Shutdown();
    
    // Shutdown Frida integration
    FridaIntegration_Shutdown();
    
    // Destroy MetalFX context
    if (g_metalFXContext) {
        MetalFX_DestroyContext(g_metalFXContext);
        g_metalFXContext = nullptr;
    }
    
    g_initialized = false;
    Logger::Info("Shutdown complete");
    Logger::Shutdown();
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
    // On macOS, RED4ext's runtime versioning doesn't always line up with the game's reported product version.
    // We only use the SDK headers, so we can mark this plugin as runtime-independent.
    aInfo->runtime = RED4EXT_RUNTIME_INDEPENDENT;
    aInfo->sdk = RED4EXT_SDK_LATEST;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports() {
    return RED4EXT_API_VERSION_LATEST;
}
