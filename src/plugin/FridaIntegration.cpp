/**
 * @file FridaIntegration.cpp
 * @brief Frida hook integration implementation
 */

#include "FridaIntegration.hpp"
#include "BufferInterceptor.hpp"
#include "Config.hpp"
#include "MetalBridge.h"

#include <iostream>
#include <atomic>
#include <chrono>
#include <vector>
#include <cstdio>
#include <mutex>
#include <cstring>

#include <mach/mach.h>
#include <mach/mach_vm.h>

// Global state
static MetalFXContext* g_context = nullptr;
static std::atomic<bool> g_active{false};
static std::atomic<uint64_t> g_framesProcessed{0};
static std::atomic<uint64_t> g_framesFallback{0};
static std::atomic<double> g_totalTimeMs{0};
static std::atomic<float> g_jitterX{0.0f};
static std::atomic<float> g_jitterY{0.0f};
static std::atomic<bool> g_cameraCut{false};

static std::mutex g_nrdMutex;
static uint8_t g_lastNrdInputs[512] = {};
static uint32_t g_lastNrdInputsSize = 0;

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
    if (!config.enabled || !config.features.restirGI) {
        g_framesFallback++;
        return false;
    }
    
    auto start = std::chrono::high_resolution_clock::now();
    
    // Extract buffers
    BufferInterceptor::SetCurrentFeatureTextures(MetalFXFeature_ReSTIRGI, inputBuffer, outputBuffer);
    BufferInfo input = BufferInterceptor::ExtractBuffer(inputBuffer);
    BufferInfo output = BufferInterceptor::ExtractBuffer(outputBuffer);
    if (!input.texture || !output.texture) {
        input = BufferInterceptor::GetCurrentFeatureColor(MetalFXFeature_ReSTIRGI);
        output = BufferInterceptor::GetCurrentFeatureOutput(MetalFXFeature_ReSTIRGI);
    }
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
    params.jitterX = g_jitterX.load();
    params.jitterY = g_jitterY.load();
    params.reset = g_cameraCut.exchange(false);
    
    // Denoise
    bool success = MetalFX_Denoise(g_context, MetalFXFeature_ReSTIRGI, cmdBuffer, &params);
    
    if (success) {
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start).count();
        
        uint64_t frames = g_framesProcessed.fetch_add(1) + 1;
        double total = g_totalTimeMs.load();
        g_totalTimeMs.store((total * (frames - 1) + ms) / frames);

        if (config.debug.logPerformance > 0 && (frames % (uint64_t)config.debug.logPerformance) == 0) {
            std::cerr << "[MetalFX] avg_ms=" << g_totalTimeMs.load()
                      << " processed=" << g_framesProcessed.load()
                      << " fallback=" << g_framesFallback.load()
                      << std::endl;
        }
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
    if (config.features.restirGI && diffuseInput && diffuseOutput) {
        BufferInterceptor::SetCurrentFeatureTextures(MetalFXFeature_ReSTIRGI, diffuseInput, diffuseOutput);
        BufferInfo input = BufferInterceptor::ExtractBuffer(diffuseInput);
        BufferInfo output = BufferInterceptor::ExtractBuffer(diffuseOutput);

        if (!input.texture || !output.texture) {
            input = BufferInterceptor::GetCurrentFeatureColor(MetalFXFeature_ReSTIRGI);
            output = BufferInterceptor::GetCurrentFeatureOutput(MetalFXFeature_ReSTIRGI);
        }
        
        if (input.texture && output.texture) {
            MetalFXDenoiseParams params = {};
            params.colorTexture = input.texture;
            params.motionVectors = motion.texture;
            params.depthTexture = depth.texture;
            params.outputTexture = output.texture;
            params.jitterX = g_jitterX.load();
            params.jitterY = g_jitterY.load();
            params.reset = g_cameraCut.load();
            
            success &= MetalFX_Denoise(g_context, MetalFXFeature_ReSTIRGI, cmdBuffer, &params);
        }
    }
    
    // Process specular
    if (config.features.reflections && specularInput && specularOutput) {
        BufferInterceptor::SetCurrentFeatureTextures(MetalFXFeature_Reflections, specularInput, specularOutput);
        BufferInfo input = BufferInterceptor::ExtractBuffer(specularInput);
        BufferInfo output = BufferInterceptor::ExtractBuffer(specularOutput);

        if (!input.texture || !output.texture) {
            input = BufferInterceptor::GetCurrentFeatureColor(MetalFXFeature_Reflections);
            output = BufferInterceptor::GetCurrentFeatureOutput(MetalFXFeature_Reflections);
        }
        
        if (input.texture && output.texture) {
            MetalFXDenoiseParams params = {};
            params.colorTexture = input.texture;
            params.motionVectors = motion.texture;
            params.depthTexture = depth.texture;
            params.outputTexture = output.texture;
            params.jitterX = g_jitterX.load();
            params.jitterY = g_jitterY.load();
            params.reset = false;  // Already reset for diffuse
            
            success &= MetalFX_Denoise(g_context, MetalFXFeature_Reflections, cmdBuffer, &params);
        }
    }
    
    g_cameraCut.store(false);
    
    if (success) {
        auto end = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(end - start).count();
        
        uint64_t frames = g_framesProcessed.fetch_add(1) + 1;
        double total = g_totalTimeMs.load();
        g_totalTimeMs.store((total * (frames - 1) + ms) / frames);

        if (config.debug.logPerformance > 0 && (frames % (uint64_t)config.debug.logPerformance) == 0) {
            std::cerr << "[MetalFX] avg_ms=" << g_totalTimeMs.load()
                      << " processed=" << g_framesProcessed.load()
                      << " fallback=" << g_framesFallback.load()
                      << std::endl;
        }
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
    
    BufferInterceptor::SetCurrentFeatureTextures(MetalFXFeature_Shadows, shadowInput, shadowOutput);
    BufferInfo input = BufferInterceptor::ExtractBuffer(shadowInput);
    BufferInfo output = BufferInterceptor::ExtractBuffer(shadowOutput);
    if (!input.texture || !output.texture) {
        input = BufferInterceptor::GetCurrentFeatureColor(MetalFXFeature_Shadows);
        output = BufferInterceptor::GetCurrentFeatureOutput(MetalFXFeature_Shadows);
    }
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
    params.jitterX = g_jitterX.load();
    params.jitterY = g_jitterY.load();
    params.reset = g_cameraCut.exchange(false);
    
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

    // Best-effort safe dump (avoid crashing on bad pointers)
    auto safeDump = [](const void* p, size_t n) {
        std::string out;
        out.reserve(n * 3);
        std::vector<unsigned char> buf(n);
        mach_vm_size_t outSize = 0;
        const kern_return_t kr = mach_vm_read_overwrite(
            mach_task_self(),
            static_cast<mach_vm_address_t>(reinterpret_cast<uintptr_t>(p)),
            static_cast<mach_vm_size_t>(n),
            reinterpret_cast<mach_vm_address_t>(buf.data()),
            &outSize);
        if (kr != KERN_SUCCESS || outSize != n) {
            return std::string("<unreadable>");
        }
        char tmp[8];
        for (size_t i = 0; i < n; i++) {
            std::snprintf(tmp, sizeof(tmp), "%02X ", buf[i]);
            out += tmp;
            if ((i + 1) % 16 == 0) out += '\n';
        }
        return out;
    };

    {
        std::lock_guard<std::mutex> lock(g_nrdMutex);
        mach_vm_size_t outSize = 0;
        const kern_return_t kr = mach_vm_read_overwrite(
            mach_task_self(),
            static_cast<mach_vm_address_t>(reinterpret_cast<uintptr_t>(config)),
            static_cast<mach_vm_size_t>(sizeof(g_lastNrdInputs)),
            reinterpret_cast<mach_vm_address_t>(g_lastNrdInputs),
            &outSize);
        g_lastNrdInputsSize = (kr == KERN_SUCCESS) ? static_cast<uint32_t>(outSize) : 0;
    }

    std::cerr << "[MetalFX] NrdInputs first 128 bytes:\n" << safeDump(config, 128) << std::endl;

    // Heuristic scan: find plausible width/height pairs (little-endian uint32)
    const auto isDim = [](uint32_t v) { return v >= 640 && v <= 8192; };
    std::vector<std::pair<uint32_t, uint32_t>> dims;
    {
        std::lock_guard<std::mutex> lock(g_nrdMutex);
        for (uint32_t off = 0; off + 8 <= g_lastNrdInputsSize; off += 4) {
            uint32_t w = 0, h = 0;
            std::memcpy(&w, g_lastNrdInputs + off, 4);
            std::memcpy(&h, g_lastNrdInputs + off + 4, 4);
            if (isDim(w) && isDim(h)) {
                dims.emplace_back(w, h);
                if (dims.size() >= 8) break;
            }
        }
    }
    if (!dims.empty()) {
        std::cerr << "[MetalFX] NrdInputs candidate dims (heuristic):" << std::endl;
        for (const auto& [w, h] : dims) {
            std::cerr << "  " << w << "x" << h << std::endl;
        }
    }
    
    // TODO: Parse config structure to extract:
    // - Render resolution
    // - Buffer formats
    // - Denoiser mode
}

uint32_t MetalFX_GetLastNrdInputsSnapshot(void* outBuffer, uint32_t capacity) {
    if (!outBuffer || capacity == 0) return 0;
    std::lock_guard<std::mutex> lock(g_nrdMutex);
    uint32_t n = g_lastNrdInputsSize;
    if (n > capacity) n = capacity;
    std::memcpy(outBuffer, g_lastNrdInputs, n);
    return n;
}

void MetalFX_ClearLastNrdInputsSnapshot(void) {
    std::lock_guard<std::mutex> lock(g_nrdMutex);
    std::memset(g_lastNrdInputs, 0, sizeof(g_lastNrdInputs));
    g_lastNrdInputsSize = 0;
}

void MetalFX_PluginSetMotionVectorMode(int mode, bool flipY) {
    if (!g_context) return;
    MetalFX_SetMotionVectorMode(g_context, (MetalFXMotionVectorMode)mode, flipY);
}

void MetalFX_SetJitter(float x, float y) {
    g_jitterX.store(x);
    g_jitterY.store(y);
}

void MetalFX_SignalCameraCut(void) {
    g_cameraCut.store(true);
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

void MetalFX_SetCurrentResources(
    void* motionVectors,
    void* depthBuffer,
    void* commandBuffer,
    float jitterX,
    float jitterY,
    bool resetHistory)
{
    // Make the frida-provided per-frame values the authoritative source.
    g_jitterX.store(jitterX);
    g_jitterY.store(jitterY);
    if (resetHistory) {
        g_cameraCut.store(true);
    }
    BufferInterceptor::SetCurrentResources(
        motionVectors,
        depthBuffer,
        commandBuffer,
        jitterX,
        jitterY,
        resetHistory);
}

void MetalFX_SetCurrentFeatureTextures(int feature, void* colorTexture, void* outputTexture) {
    if (feature < 0 || feature >= MetalFXFeature_Count) {
        return;
    }
    BufferInterceptor::SetCurrentFeatureTextures(
        static_cast<MetalFXFeature>(feature),
        colorTexture,
        outputTexture);
}

} // extern "C"
