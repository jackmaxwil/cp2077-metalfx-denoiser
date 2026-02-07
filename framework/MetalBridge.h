#pragma once

/**
 * @file MetalBridge.h
 * @brief C interface to MetalFX denoiser framework
 * 
 * This header provides a C-compatible interface that can be called from
 * the C++ RED4ext plugin. It bridges the gap between C++ hooks and the
 * Objective-C MetalFX implementation.
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

// Opaque handle types
typedef struct MetalFXContext MetalFXContext;
typedef void* MTLDeviceRef;
typedef void* MTLTextureRef;
typedef void* MTLCommandBufferRef;

/**
 * RT feature types that can be denoised
 */
typedef enum {
    MetalFXFeature_Shadows = 0,
    MetalFXFeature_RTXDIDiffuse = 1,
    MetalFXFeature_RTXDISpecular = 2,
    MetalFXFeature_ReSTIRGI = 3,
    MetalFXFeature_Reflections = 4,
    MetalFXFeature_AO = 5,
    MetalFXFeature_Count = 6
} MetalFXFeature;

/**
 * Denoiser quality levels
 */
typedef enum {
    MetalFXQuality_Performance = 0,
    MetalFXQuality_Balanced = 1,
    MetalFXQuality_Quality = 2
} MetalFXQuality;

/**
 * Motion vector input interpretation.
 */
typedef enum {
    MetalFXMotionVectors_Passthrough = 0,
    MetalFXMotionVectors_NDCToPixels = 1
} MetalFXMotionVectorMode;

/**
 * Input parameters for denoising operation
 */
typedef struct {
    MTLTextureRef colorTexture;        // Noisy input (RGBA16Float)
    MTLTextureRef motionVectors;       // Motion vectors (RG16Float or RG32Float)
    MTLTextureRef depthTexture;        // Depth buffer (Depth32Float)
    MTLTextureRef outputTexture;       // Denoised output (RGBA16Float)
    float jitterX;                     // TAA jitter X offset
    float jitterY;                     // TAA jitter Y offset
    bool reset;                        // Reset temporal history
} MetalFXDenoiseParams;

/**
 * Performance metrics
 */
typedef struct {
    double gpuTimeMs;                  // GPU execution time in milliseconds
    uint64_t frameIndex;               // Current frame index
} MetalFXMetrics;

// =============================================================================
// Lifecycle Functions
// =============================================================================

/**
 * Initialize the MetalFX denoiser context
 * @param device Metal device from game (nullable, will use default)
 * @return Context handle, or NULL on failure
 */
MetalFXContext* MetalFX_CreateContext(MTLDeviceRef device);

/**
 * Destroy the MetalFX denoiser context
 * @param ctx Context to destroy
 */
void MetalFX_DestroyContext(MetalFXContext* ctx);

/**
 * Check if MetalFX is available on this system
 * @return true if MetalFX temporal scaler is supported
 */
bool MetalFX_IsSupported(void);

// =============================================================================
// Configuration Functions
// =============================================================================

/**
 * Configure the scaler for a specific resolution
 * @param ctx Context handle
 * @param feature RT feature to configure
 * @param width Input width
 * @param height Input height
 * @param quality Quality preset
 * @return true on success
 */
bool MetalFX_ConfigureScaler(
    MetalFXContext* ctx,
    MetalFXFeature feature,
    uint32_t width,
    uint32_t height,
    MetalFXQuality quality
);

/**
 * Enable or disable a specific feature
 * @param ctx Context handle
 * @param feature Feature to configure
 * @param enabled Whether to enable the feature
 */
void MetalFX_SetFeatureEnabled(MetalFXContext* ctx, MetalFXFeature feature, bool enabled);

/**
 * Check if a feature is enabled
 * @param ctx Context handle
 * @param feature Feature to check
 * @return true if enabled
 */
bool MetalFX_IsFeatureEnabled(MetalFXContext* ctx, MetalFXFeature feature);

// =============================================================================
// Denoising Functions
// =============================================================================

/**
 * Perform denoising for a specific feature
 * @param ctx Context handle
 * @param feature RT feature to denoise
 * @param cmdBuffer Command buffer to encode into
 * @param params Denoising parameters
 * @return true on success
 */
bool MetalFX_Denoise(
    MetalFXContext* ctx,
    MetalFXFeature feature,
    MTLCommandBufferRef cmdBuffer,
    const MetalFXDenoiseParams* params
);

/**
 * Configure motion vector interpretation/conversion.
 */
void MetalFX_SetMotionVectorMode(MetalFXContext* ctx, MetalFXMotionVectorMode mode, bool flipY);

/**
 * Get the Metal device used by the context
 * @param ctx Context handle
 * @return Metal device reference
 */
MTLDeviceRef MetalFX_GetDevice(MetalFXContext* ctx);

// =============================================================================
// Metrics Functions
// =============================================================================

/**
 * Get performance metrics for a feature
 * @param ctx Context handle
 * @param feature Feature to query
 * @param metrics Output metrics structure
 */
void MetalFX_GetMetrics(MetalFXContext* ctx, MetalFXFeature feature, MetalFXMetrics* metrics);

/**
 * Reset metrics counters
 * @param ctx Context handle
 */
void MetalFX_ResetMetrics(MetalFXContext* ctx);

#ifdef __cplusplus
}
#endif
