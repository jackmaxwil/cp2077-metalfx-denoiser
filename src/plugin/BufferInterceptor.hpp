#pragma once

/**
 * @file BufferInterceptor.hpp
 * @brief Game buffer interception and extraction
 */

#include <cstdint>

#include "MetalBridge.h"

/**
 * Information about an extracted buffer
 */
struct BufferInfo {
    void* texture;          // MTLTexture pointer
    uint32_t width;
    uint32_t height;
    uint32_t format;        // MTLPixelFormat
    const char* name;       // Debug name
};

namespace BufferInterceptor {

/**
 * Initialize buffer interception
 */
bool Initialize();

/**
 * Shutdown buffer interception
 */
void Shutdown();

/**
 * Extract buffer info from game buffer structure
 * @param gameBuffer Pointer to game's internal buffer structure
 * @return Buffer info with Metal texture
 */
BufferInfo ExtractBuffer(void* gameBuffer);

/**
 * Get current motion vectors buffer
 */
BufferInfo GetMotionVectors();

/**
 * Get current depth buffer
 */
BufferInfo GetDepthBuffer();

/**
 * Get current command buffer
 */
void* GetCurrentCommandBuffer();

/**
 * Get TAA jitter offset X
 */
float GetJitterX();

/**
 * Get TAA jitter offset Y
 */
float GetJitterY();

/**
 * Check if temporal history needs reset (camera cut)
 */
bool NeedsHistoryReset();

/**
 * Set the current frame's Metal resources
 * Called by render hooks to provide access to game resources
 */
void SetCurrentResources(
    void* motionVectors,
    void* depthBuffer,
    void* commandBuffer,
    float jitterX,
    float jitterY,
    bool resetHistory
);

/**
 * Set the current frame's textures for a specific denoising feature.
 * Intended for the Metal compute interception path, where the true MTLTexture pointers are known.
 */
void SetCurrentFeatureTextures(MetalFXFeature feature, void* colorTexture, void* outputTexture);

/**
 * Get the last provided color texture for a feature.
 */
BufferInfo GetCurrentFeatureColor(MetalFXFeature feature);

/**
 * Get the last provided output texture for a feature.
 */
BufferInfo GetCurrentFeatureOutput(MetalFXFeature feature);

} // namespace BufferInterceptor
