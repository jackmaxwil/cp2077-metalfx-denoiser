#pragma once

/**
 * @file FridaIntegration.hpp
 * @brief Frida hook integration for MetalFX Denoiser
 * 
 * Provides exports that can be called from Frida JavaScript hooks
 * to perform actual MetalFX denoising operations.
 */

#include "../framework/MetalBridge.h"
#include <cstdint>

extern "C" {

/**
 * Called from Frida hook when REBLUR_Diffuse is intercepted
 * @param denoiserState Original denoiser state pointer
 * @param inputBuffer Input texture wrapper
 * @param outputBuffer Output texture wrapper
 * @return true if MetalFX processed, false to use original
 */
bool MetalFX_HookREBLUR_Diffuse(void* denoiserState, void* inputBuffer, void* outputBuffer);

/**
 * Called from Frida hook when REBLUR_DiffuseSpecular is intercepted
 */
bool MetalFX_HookREBLUR_DiffuseSpecular(
    void* denoiserState,
    void* diffuseInput, void* specularInput,
    void* diffuseOutput, void* specularOutput
);

/**
 * Called from Frida hook when SIGMA_Shadow is intercepted
 */
bool MetalFX_HookSIGMA_Shadow(void* filterState, void* shadowInput, void* shadowOutput);

/**
 * Called from Frida hook when NrdInputs is configured
 * Used to extract buffer format information
 */
void MetalFX_OnNrdInputsConfigured(void* config);

/**
 * Set global jitter values for temporal accumulation
 */
void MetalFX_SetJitter(float x, float y);

/**
 * Signal camera cut (reset temporal history)
 */
void MetalFX_SignalCameraCut(void);

/**
 * Query if MetalFX replacement is active
 */
bool MetalFX_IsReplacementActive(void);

/**
 * Get performance metrics
 */
void MetalFX_GetPerformanceMetrics(
    double* avgTimeMs,
    uint64_t* framesProcessed,
    uint64_t* framesFallback
);

}
