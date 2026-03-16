/**
 * @file NRDHooks.cpp
 * @brief NRD function hook implementation
 * 
 * This file implements hooks that intercept NRD denoiser calls and
 * redirect them to MetalFX Temporal Scaler.
 */

#include "NRDHooks.hpp"
#include "BufferInterceptor.hpp"
#include "Config.hpp"
#include "Logger.hpp"
#include "Support/macOS/AddressResolverOverride.hpp"

#include <iostream>
#include <atomic>
#include <cstdint>
#include <string>

// Frida/fishhook for hooking on macOS
// In production, use RED4ext's hooking infrastructure
#include <dlfcn.h>
#include <RED4ext/Relocation.hpp>

namespace NRDHooks {

// =============================================================================
// State
// =============================================================================

static MetalFXContext* s_context = nullptr;
static std::atomic<bool> s_enabled{true};
static std::atomic<uint64_t> s_frameCount{0};
static bool s_initialized = false;

// Original function pointers (for trampolines)
using REBLURFunc = void(*)(void*, void*, void*);
static REBLURFunc s_originalREBLUR_Diffuse = nullptr;
static REBLURFunc s_originalREBLUR_DiffuseSpecular = nullptr;

// =============================================================================
// Hook Implementations
// =============================================================================

/**
 * REBLUR Diffuse hook
 * Called for diffuse GI denoising
 */
void HookedREBLUR_Diffuse(void* denoiserState, void* inputBuffer, void* outputBuffer) {
    const auto& config = Config::Get();

    if (!s_enabled.load() || !s_context) {
        // Passthrough to original
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }

    if (!config.enabled || !config.features.restirGI) {
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Extract textures from game buffers
    // TODO: Reverse engineer actual buffer structures
    BufferInfo input = BufferInterceptor::ExtractBuffer(inputBuffer);
    BufferInfo output = BufferInterceptor::ExtractBuffer(outputBuffer);
    
    if (!input.texture || !output.texture) {
        Logger::Warn("Failed to extract textures for REBLUR_Diffuse");
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Get motion vectors and depth from interceptor
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    
    if (!motion.texture || !depth.texture) {
        Logger::Warn("Missing motion/depth for REBLUR_Diffuse");
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Create denoising params
    MetalFXDenoiseParams params = {};
    params.colorTexture = input.texture;
    params.motionVectors = motion.texture;
    params.depthTexture = depth.texture;
    params.outputTexture = output.texture;
    params.jitterX = BufferInterceptor::GetJitterX();
    params.jitterY = BufferInterceptor::GetJitterY();
    params.reset = BufferInterceptor::NeedsHistoryReset();
    
    // Get command buffer
    void* cmdBuffer = BufferInterceptor::GetCurrentCommandBuffer();
    if (!cmdBuffer) {
        Logger::Warn("No command buffer available");
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Perform MetalFX denoising
    if (!MetalFX_Denoise(s_context, MetalFXFeature_ReSTIRGI, cmdBuffer, &params)) {
        Logger::Warn("MetalFX denoising failed for REBLUR_Diffuse");
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    s_frameCount++;
    
    // Skip original NRD call - output is already filled by MetalFX
}

/**
 * REBLUR DiffuseSpecular hook
 * Called for combined diffuse+specular denoising
 */
void HookedREBLUR_DiffuseSpecular(void* denoiserState, void* inputBuffer, void* outputBuffer) {
    const auto& config = Config::Get();

    if (!s_enabled.load() || !s_context) {
        if (s_originalREBLUR_DiffuseSpecular) {
            s_originalREBLUR_DiffuseSpecular(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }

    if (!config.enabled) {
        if (s_originalREBLUR_DiffuseSpecular) {
            s_originalREBLUR_DiffuseSpecular(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // For combined pass, denoise both channels
    // TODO: May need separate textures for diffuse/specular
    BufferInfo input = BufferInterceptor::ExtractBuffer(inputBuffer);
    BufferInfo output = BufferInterceptor::ExtractBuffer(outputBuffer);
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    void* cmdBuffer = BufferInterceptor::GetCurrentCommandBuffer();
    
    if (!input.texture || !output.texture || !motion.texture || 
        !depth.texture || !cmdBuffer) {
        if (s_originalREBLUR_DiffuseSpecular) {
            s_originalREBLUR_DiffuseSpecular(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    MetalFXDenoiseParams params = {};
    params.colorTexture = input.texture;
    params.motionVectors = motion.texture;
    params.depthTexture = depth.texture;
    params.outputTexture = output.texture;
    params.jitterX = BufferInterceptor::GetJitterX();
    params.jitterY = BufferInterceptor::GetJitterY();
    params.reset = BufferInterceptor::NeedsHistoryReset();
    
    // Denoise combined buffer (best-effort); fallback to original on failure
    const bool ok = MetalFX_Denoise(s_context, MetalFXFeature_ReSTIRGI, cmdBuffer, &params);

    if (!ok) {
        if (s_originalREBLUR_DiffuseSpecular) {
            s_originalREBLUR_DiffuseSpecular(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // TODO: Denoise specular separately if textures are split
    // MetalFX_Denoise(s_context, MetalFXFeature_RTXDISpecular, cmdBuffer, &specularParams);
    
    s_frameCount++;
}

// =============================================================================
// Hook Management
// =============================================================================

/**
 * Get function pointer from address
 */
template<typename T>
T GetFunctionPointer(uintptr_t offset) {
    // Use canonical SDK base resolution helper.
    const uintptr_t base = RED4ext::RelocBase::GetImageBase();
    if (!base) {
        Logger::Error("Failed to get image base");
        return nullptr;
    }
    uintptr_t addr = base + offset;
    
    return reinterpret_cast<T>(addr);
}

bool Initialize(MetalFXContext* ctx) {
    if (s_initialized) {
        return true;
    }
    
    s_context = ctx;
    
    // Log which addresses we're using
    Logger::Info(std::string("Using NRD addresses for game v") + NRD::Address::GAME_VERSION);
    
    // Validate addresses are in reasonable range
    if (!NRD::Address::ValidateAddresses()) {
        Logger::Warn("Address validation indicates offsets may be outdated");
        Logger::Warn("Hook resolution may fail - check game version compatibility");
        // Continue anyway but warn - let it fail naturally if addresses are truly wrong
    }
    
    Logger::Info("Attaching hooks to NRD functions...");
    
    // Get original function pointers
    s_originalREBLUR_Diffuse = GetFunctionPointer<REBLURFunc>(NRD::Address::REBLUR_Diffuse);
    s_originalREBLUR_DiffuseSpecular = GetFunctionPointer<REBLURFunc>(NRD::Address::REBLUR_DiffuseSpecular);
    
    if (!s_originalREBLUR_Diffuse || !s_originalREBLUR_DiffuseSpecular) {
        Logger::Warn("Failed to resolve NRD function addresses");
        // Don't fail - addresses might be wrong but we can still try runtime hooking
    } else {
        Logger::Info("Successfully resolved NRD function addresses");
    }
    
    // TODO: Use Frida or RED4ext hooking to actually install hooks
    // For now, we have the infrastructure but need runtime hooking
    
    // Initialize buffer interceptor
    if (!BufferInterceptor::Initialize()) {
        Logger::Warn("Buffer interceptor initialization failed");
    }
    
    s_initialized = true;
    Logger::Info("Hook infrastructure initialized");
    Logger::Info("Runtime hook installation requires Frida integration");
    Logger::Info("Load: frida -l metalfx_hooks.js -p <pid>");
    
    return true;
}

void Shutdown() {
    if (!s_initialized) {
        return;
    }
    
    Logger::Info("Detaching NRD hooks...");
    
    // TODO: Detach Frida hooks
    
    BufferInterceptor::Shutdown();
    
    s_context = nullptr;
    s_originalREBLUR_Diffuse = nullptr;
    s_originalREBLUR_DiffuseSpecular = nullptr;
    s_initialized = false;
    
    Logger::Info(std::string("Hooks detached, processed ") + std::to_string(s_frameCount.load()) + " frames");
}

void SetEnabled(bool enabled) {
    s_enabled.store(enabled);
    Logger::Info(std::string("Hook ") + (enabled ? "enabled" : "disabled"));
}

bool IsEnabled() {
    return s_enabled.load();
}

uint64_t GetFrameCount() {
    return s_frameCount.load();
}

} // namespace NRDHooks
