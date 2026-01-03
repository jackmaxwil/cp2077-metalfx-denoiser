/**
 * @file FridaIntegration.cpp
 * @brief Frida hook integration implementation
 */

#include "FridaIntegration.hpp"
#include "BufferInterceptor.hpp"
#include "Config.hpp"
#include "../framework/MetalBridge.h"

#include <iostream>
#include <atomic>
#include <chrono>

// Global state
static MetalFXContext* g_context = nullptr;
static std::atomic<bool> g_active{false};
static std::atomic<uint64_t> g_framesProcessed{0};
static std::atomic<uint64_t> g_framesFallback{0};
static std::atomic<double> g_totalTimeMs{0};
static float g_jitterX = 0.0f;
static float g_jitterY = 0.0f;
static bool g_cameraCut = false;

// Initialize (called from main.cpp)
void FridaIntegration_Init(MetalFXContext* ctx) {
    g_context = ctx;
    g_active.store(ctx != nullptr);
}

void FridaIntegration_Shutdown() {
    g_active.store(false);
    g_context = nullptr;
}

extern "C" {

bool MetalFX_HookREBLUR_Diffuse(void* denoiserState, void* inputBuffer, void* outputBuffer) {
    if (!g_active.load() || !g_context) {
        g_framesFallback++;
        return false;
    }
    
    const auto& config = Config::Get();
    if (!config.enabled || !config.features.rtxdiDiffuse) {
        g_framesFallback++;
        return false;
    }
    
    auto start = std::chrono::high_resolution_clock::now();
    
    // Extract buffers
    BufferInfo input = BufferInterceptor::ExtractBuffer(inputBuffer);
    BufferInfo output = BufferInterceptor::ExtractBuffer(outputBuffer);
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    void* cmdBuffer = BufferInterceptor::GetCurrentCommandBuffer();
    
    if (!input.texture || !output.texture || !motion.texture || !depth.texture || !cmdBuffer) {
        std::cerr << "[MetalFX] Buffer extraction failed for REBLUR_Diffuse" << std::endl;
        g_framesFallback++;
        return false;
    }
    
    // Prepare params
    MetalFXDenoiseParams params = {};
    params.colorTexture = input.texture;
    params.motionVectors = motion.texture;
    params.depthTexture = depth.texture;
    params.outputTexture = output.texture;
    params.jitterX = g_jitterX;
    params.jitterY = g_jitterY;
    params.reset = g_cameraCut;
    g_cameraCut = false;
    
    // Denoise
    bool success = MetalFX_Denoise(g_context, MetalFXFeature_RTXDIDiffuse, cmdBuffer, &params);
    
    if (success) {
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start).count();
        
        uint64_t frames = g_framesProcessed.fetch_add(1) + 1;
        double total = g_totalTimeMs.load();
        g_totalTimeMs.store((total * (frames - 1) + ms) / frames);
    } else {
        g_framesFallback++;
    }
    
    return success;
}

bool MetalFX_HookREBLUR_DiffuseSpecular(
    void* denoiserState,
    void* diffuseInput, void* specularInput,
    void* diffuseOutput, void* specularOutput)
{
    if (!g_active.load() || !g_context) {
        g_framesFallback++;
        return false;
    }
    
    const auto& config = Config::Get();
    if (!config.enabled) {
        g_framesFallback++;
        return false;
    }
    
    auto start = std::chrono::high_resolution_clock::now();
    bool success = true;
    
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    void* cmdBuffer = BufferInterceptor::GetCurrentCommandBuffer();
    
    if (!motion.texture || !depth.texture || !cmdBuffer) {
        g_framesFallback++;
        return false;
    }
    
    // Process diffuse
    if (config.features.rtxdiDiffuse && diffuseInput && diffuseOutput) {
        BufferInfo input = BufferInterceptor::ExtractBuffer(diffuseInput);
        BufferInfo output = BufferInterceptor::ExtractBuffer(diffuseOutput);
        
        if (input.texture && output.texture) {
            MetalFXDenoiseParams params = {};
            params.colorTexture = input.texture;
            params.motionVectors = motion.texture;
            params.depthTexture = depth.texture;
            params.outputTexture = output.texture;
            params.jitterX = g_jitterX;
            params.jitterY = g_jitterY;
            params.reset = g_cameraCut;
            
            success &= MetalFX_Denoise(g_context, MetalFXFeature_RTXDIDiffuse, cmdBuffer, &params);
        }
    }
    
    // Process specular
    if (config.features.rtxdiSpecular && specularInput && specularOutput) {
        BufferInfo input = BufferInterceptor::ExtractBuffer(specularInput);
        BufferInfo output = BufferInterceptor::ExtractBuffer(specularOutput);
        
        if (input.texture && output.texture) {
            MetalFXDenoiseParams params = {};
            params.colorTexture = input.texture;
            params.motionVectors = motion.texture;
            params.depthTexture = depth.texture;
            params.outputTexture = output.texture;
            params.jitterX = g_jitterX;
            params.jitterY = g_jitterY;
            params.reset = false;  // Already reset for diffuse
            
            success &= MetalFX_Denoise(g_context, MetalFXFeature_RTXDISpecular, cmdBuffer, &params);
        }
    }
    
    g_cameraCut = false;
    
    if (success) {
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start).count();
        
        uint64_t frames = g_framesProcessed.fetch_add(1) + 1;
        double total = g_totalTimeMs.load();
        g_totalTimeMs.store((total * (frames - 1) + ms) / frames);
    } else {
        g_framesFallback++;
    }
    
    return success;
}

bool MetalFX_HookSIGMA_Shadow(void* filterState, void* shadowInput, void* shadowOutput) {
    if (!g_active.load() || !g_context) {
        g_framesFallback++;
        return false;
    }
    
    const auto& config = Config::Get();
    if (!config.enabled || !config.features.shadows) {
        g_framesFallback++;
        return false;
    }
    
    BufferInfo input = BufferInterceptor::ExtractBuffer(shadowInput);
    BufferInfo output = BufferInterceptor::ExtractBuffer(shadowOutput);
    BufferInfo motion = BufferInterceptor::GetMotionVectors();
    BufferInfo depth = BufferInterceptor::GetDepthBuffer();
    void* cmdBuffer = BufferInterceptor::GetCurrentCommandBuffer();
    
    if (!input.texture || !output.texture || !motion.texture || !depth.texture || !cmdBuffer) {
        g_framesFallback++;
        return false;
    }
    
    MetalFXDenoiseParams params = {};
    params.colorTexture = input.texture;
    params.motionVectors = motion.texture;
    params.depthTexture = depth.texture;
    params.outputTexture = output.texture;
    params.jitterX = g_jitterX;
    params.jitterY = g_jitterY;
    params.reset = g_cameraCut;
    g_cameraCut = false;
    
    bool success = MetalFX_Denoise(g_context, MetalFXFeature_Shadows, cmdBuffer, &params);
    
    if (!success) {
        g_framesFallback++;
    }
    
    return success;
}

void MetalFX_OnNrdInputsConfigured(void* config) {
    if (!config) return;
    
    // Log for debugging
    std::cerr << "[MetalFX] NRD inputs configured at " << config << std::endl;
    
    // TODO: Parse config structure to extract:
    // - Render resolution
    // - Buffer formats
    // - Denoiser mode
}

void MetalFX_SetJitter(float x, float y) {
    g_jitterX = x;
    g_jitterY = y;
}

void MetalFX_SignalCameraCut(void) {
    g_cameraCut = true;
}

bool MetalFX_IsReplacementActive(void) {
    return g_active.load() && g_context != nullptr;
}

void MetalFX_GetPerformanceMetrics(
    double* avgTimeMs,
    uint64_t* framesProcessed,
    uint64_t* framesFallback)
{
    if (avgTimeMs) *avgTimeMs = g_totalTimeMs.load();
    if (framesProcessed) *framesProcessed = g_framesProcessed.load();
    if (framesFallback) *framesFallback = g_framesFallback.load();
}

} // extern "C"
