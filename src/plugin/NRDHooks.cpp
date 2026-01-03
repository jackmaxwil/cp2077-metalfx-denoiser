/**
 * @file NRDHooks.cpp
 * @brief NRD function hook implementation
 * 
 * This file implements hooks that intercept NRD denoiser calls and
 * redirect them to MetalFX Temporal Scaler.
 */

#include "NRDHooks.hpp"
#include "BufferInterceptor.hpp"
#include "../../lib/Support/macOS/AddressResolverOverride.hpp"

#include <iostream>
#include <atomic>
#include <cstdint>

// Frida/fishhook for hooking on macOS
// In production, use RED4ext's hooking infrastructure
#include <mach-o/dyld.h>
#include <dlfcn.h>

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
    if (!s_enabled.load() || !s_context) {
        // Passthrough to original
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
        std::cerr << "[MetalFXDenoiser] Failed to extract textures for REBLUR_Diffuse" << std::endl;
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Get motion vectors and depth from interceptor
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    
    if (!motion.texture || !depth.texture) {
        std::cerr << "[MetalFXDenoiser] Missing motion/depth for REBLUR_Diffuse" << std::endl;
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
        std::cerr << "[MetalFXDenoiser] No command buffer available" << std::endl;
        if (s_originalREBLUR_Diffuse) {
            s_originalREBLUR_Diffuse(denoiserState, inputBuffer, outputBuffer);
        }
        return;
    }
    
    // Perform MetalFX denoising
    if (!MetalFX_Denoise(s_context, MetalFXFeature_RTXDIDiffuse, cmdBuffer, &params)) {
        std::cerr << "[MetalFXDenoiser] MetalFX denoising failed for REBLUR_Diffuse" << std::endl;
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
    if (!s_enabled.load() || !s_context) {
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
    
    // Denoise diffuse channel
    MetalFX_Denoise(s_context, MetalFXFeature_RTXDIDiffuse, cmdBuffer, &params);
    
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
    // Get base address of main executable
    const struct mach_header_64* header = 
        (const struct mach_header_64*)_dyld_get_image_header(0);
    
    if (!header) {
        std::cerr << "[MetalFXDenoiser] Failed to get image header" << std::endl;
        return nullptr;
    }
    
    uintptr_t base = (uintptr_t)header;
    uintptr_t addr = base + offset;
    
    return reinterpret_cast<T>(addr);
}

bool Initialize(MetalFXContext* ctx) {
    if (s_initialized) {
        return true;
    }
    
    s_context = ctx;
    
    // Validate addresses
    if (!NRD::Address::ValidateAddresses()) {
        std::cerr << "[MetalFXDenoiser] Address validation failed - addresses may be outdated" << std::endl;
        // Continue anyway, hooks will fail gracefully
    }
    
    std::cerr << "[MetalFXDenoiser] Attaching hooks to NRD functions..." << std::endl;
    
    // Get original function pointers
    s_originalREBLUR_Diffuse = GetFunctionPointer<REBLURFunc>(NRD::Address::REBLUR_Diffuse);
    s_originalREBLUR_DiffuseSpecular = GetFunctionPointer<REBLURFunc>(NRD::Address::REBLUR_DiffuseSpecular);
    
    if (!s_originalREBLUR_Diffuse || !s_originalREBLUR_DiffuseSpecular) {
        std::cerr << "[MetalFXDenoiser] Failed to resolve NRD function addresses" << std::endl;
        std::cerr << "  REBLUR_Diffuse @ 0x" << std::hex << NRD::Address::REBLUR_Diffuse 
                  << " = " << (void*)s_originalREBLUR_Diffuse << std::endl;
        std::cerr << "  REBLUR_DiffuseSpecular @ 0x" << NRD::Address::REBLUR_DiffuseSpecular 
                  << " = " << (void*)s_originalREBLUR_DiffuseSpecular << std::endl;
        // Don't fail - addresses might be wrong but we can still try runtime hooking
    }
    
    // TODO: Use Frida or RED4ext hooking to actually install hooks
    // For now, we have the infrastructure but need runtime hooking
    
    // Initialize buffer interceptor
    if (!BufferInterceptor::Initialize()) {
        std::cerr << "[MetalFXDenoiser] Buffer interceptor initialization failed" << std::endl;
    }
    
    s_initialized = true;
    std::cerr << "[MetalFXDenoiser] Hook infrastructure initialized" << std::endl;
    std::cerr << "  NOTE: Actual hook installation requires Frida integration" << std::endl;
    
    return true;
}

void Shutdown() {
    if (!s_initialized) {
        return;
    }
    
    std::cerr << "[MetalFXDenoiser] Detaching NRD hooks..." << std::endl;
    
    // TODO: Detach Frida hooks
    
    BufferInterceptor::Shutdown();
    
    s_context = nullptr;
    s_originalREBLUR_Diffuse = nullptr;
    s_originalREBLUR_DiffuseSpecular = nullptr;
    s_initialized = false;
    
    std::cerr << "[MetalFXDenoiser] Hooks detached, processed " 
              << s_frameCount.load() << " frames" << std::endl;
}

void SetEnabled(bool enabled) {
    s_enabled.store(enabled);
    std::cerr << "[MetalFXDenoiser] Hook " << (enabled ? "enabled" : "disabled") << std::endl;
}

bool IsEnabled() {
    return s_enabled.load();
}

uint64_t GetFrameCount() {
    return s_frameCount.load();
}

} // namespace NRDHooks
