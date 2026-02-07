/**
 * @file BufferInterceptor.cpp
 * @brief Game buffer interception implementation
 * 
 * This file handles extraction of Metal textures from game's internal
 * buffer structures. The exact structure layout needs reverse engineering.
 */

#include "BufferInterceptor.hpp"
#include <iostream>
#include <mutex>

#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace BufferInterceptor {

// =============================================================================
// State
// =============================================================================

static std::mutex s_mutex;
static bool s_initialized = false;

// Current frame resources
static void* s_motionVectors = nullptr;
static void* s_depthBuffer = nullptr;
static void* s_commandBuffer = nullptr;
static float s_jitterX = 0.0f;
static float s_jitterY = 0.0f;
static bool s_resetHistory = false;

static void* s_featureColor[MetalFXFeature_Count] = {};
static void* s_featureOutput[MetalFXFeature_Count] = {};

// =============================================================================
// Safe memory probing helpers (avoid EXC_BAD_ACCESS on bad game pointers)
// =============================================================================

static bool SafeRead(uintptr_t addr, void* out, size_t size) {
    mach_vm_size_t outSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(
        mach_task_self(),
        static_cast<mach_vm_address_t>(addr),
        static_cast<mach_vm_size_t>(size),
        reinterpret_cast<mach_vm_address_t>(out),
        &outSize);
    return kr == KERN_SUCCESS && outSize == size;
}

template <typename T>
static bool SafeReadValue(uintptr_t addr, T& out) {
    return SafeRead(addr, &out, sizeof(T));
}

static bool IsReadablePointer(const void* p) {
    if (!p) return false;
    uintptr_t tmp = 0;
    return SafeReadValue(reinterpret_cast<uintptr_t>(p), tmp);
}

static bool IsPlausibleObjCObject(const void* p) {
    if (!IsReadablePointer(p)) return false;
    uintptr_t isa = 0;
    if (!SafeReadValue(reinterpret_cast<uintptr_t>(p), isa)) return false;
    if (isa == 0) return false;
    return IsReadablePointer(reinterpret_cast<const void*>(isa));
}

// =============================================================================
// Implementation
// =============================================================================

bool Initialize() {
    std::lock_guard<std::mutex> lock(s_mutex);
    
    if (s_initialized) {
        return true;
    }
    
    std::cerr << "[BufferInterceptor] Initializing..." << std::endl;
    
    // TODO: Hook into game's resource management to get texture mappings
    // This might involve:
    // 1. Finding the render context/device
    // 2. Hooking texture creation to track buffer names
    // 3. Intercepting render pass setup to get current buffers
    
    s_initialized = true;
    std::cerr << "[BufferInterceptor] Initialized" << std::endl;
    
    return true;
}

void Shutdown() {
    std::lock_guard<std::mutex> lock(s_mutex);
    
    s_motionVectors = nullptr;
    s_depthBuffer = nullptr;
    s_commandBuffer = nullptr;
    for (int i = 0; i < MetalFXFeature_Count; i++) {
        s_featureColor[i] = nullptr;
        s_featureOutput[i] = nullptr;
    }
    s_initialized = false;
    
    std::cerr << "[BufferInterceptor] Shutdown" << std::endl;
}

BufferInfo ExtractBuffer(void* gameBuffer) {
    BufferInfo info = {};
    
    if (!gameBuffer) {
        return info;
    }

    const uintptr_t base = reinterpret_cast<uintptr_t>(gameBuffer);

    // Attempt 1: texture pointer at +0x10 (common wrapper pattern)
    void* tex = nullptr;
    if (SafeReadValue(base + 0x10, tex) && tex && IsPlausibleObjCObject(tex)) {
        info.texture = tex;
        SafeReadValue(base + 0x18, info.width);
        SafeReadValue(base + 0x1C, info.height);
        SafeReadValue(base + 0x20, info.format);
        return info;
    }

    // Attempt 2: texture pointer at +0x30 (alternate wrapper pattern)
    tex = nullptr;
    if (SafeReadValue(base + 0x30, tex) && tex && IsPlausibleObjCObject(tex)) {
        info.texture = tex;
        SafeReadValue(base + 0x38, info.width);
        SafeReadValue(base + 0x3C, info.height);
        return info;
    }

    // Fallback: assume gameBuffer itself is the MTLTexture pointer
    if (IsPlausibleObjCObject(gameBuffer)) {
        info.texture = gameBuffer;
    }

    return info;
}

BufferInfo GetMotionVectors() {
    std::lock_guard<std::mutex> lock(s_mutex);
    return ExtractBuffer(s_motionVectors);
}

BufferInfo GetDepthBuffer() {
    std::lock_guard<std::mutex> lock(s_mutex);
    return ExtractBuffer(s_depthBuffer);
}

void* GetCurrentCommandBuffer() {
    std::lock_guard<std::mutex> lock(s_mutex);
    return IsPlausibleObjCObject(s_commandBuffer) ? s_commandBuffer : nullptr;
}

float GetJitterX() {
    std::lock_guard<std::mutex> lock(s_mutex);
    return s_jitterX;
}

float GetJitterY() {
    std::lock_guard<std::mutex> lock(s_mutex);
    return s_jitterY;
}

bool NeedsHistoryReset() {
    std::lock_guard<std::mutex> lock(s_mutex);
    bool reset = s_resetHistory;
    s_resetHistory = false;  // Clear after reading
    return reset;
}

void SetCurrentResources(
    void* motionVectors,
    void* depthBuffer,
    void* commandBuffer,
    float jitterX,
    float jitterY,
    bool resetHistory)
{
    std::lock_guard<std::mutex> lock(s_mutex);
    
    s_motionVectors = motionVectors;
    s_depthBuffer = depthBuffer;
    s_commandBuffer = commandBuffer;
    s_jitterX = jitterX;
    s_jitterY = jitterY;
    s_resetHistory = resetHistory;
}

void SetCurrentFeatureTextures(MetalFXFeature feature, void* colorTexture, void* outputTexture) {
    if (feature < 0 || feature >= MetalFXFeature_Count) {
        return;
    }
    std::lock_guard<std::mutex> lock(s_mutex);
    s_featureColor[feature] = IsPlausibleObjCObject(colorTexture) ? colorTexture : nullptr;
    s_featureOutput[feature] = IsPlausibleObjCObject(outputTexture) ? outputTexture : nullptr;
}

BufferInfo GetCurrentFeatureColor(MetalFXFeature feature) {
    if (feature < 0 || feature >= MetalFXFeature_Count) {
        return {};
    }
    std::lock_guard<std::mutex> lock(s_mutex);
    return ExtractBuffer(s_featureColor[feature]);
}

BufferInfo GetCurrentFeatureOutput(MetalFXFeature feature) {
    if (feature < 0 || feature >= MetalFXFeature_Count) {
        return {};
    }
    std::lock_guard<std::mutex> lock(s_mutex);
    return ExtractBuffer(s_featureOutput[feature]);
}

} // namespace BufferInterceptor
