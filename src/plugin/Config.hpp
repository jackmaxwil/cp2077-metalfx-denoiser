#pragma once

/**
 * @file Config.hpp
 * @brief Runtime configuration for MetalFX Denoiser
 */

#include <string>
#include <cstdint>

namespace Config {

/**
 * Quality preset
 */
enum class Quality {
    Performance,
    Balanced,
    Quality
};

/**
 * Feature flags
 */
struct Features {
    bool shadows = true;
    bool rtxdiDiffuse = true;
    bool rtxdiSpecular = true;
    bool restirGI = true;
    bool reflections = true;
    bool ao = true;
};

/**
 * Debug settings
 */
struct Debug {
    int logPerformance = 0;      // Log every N frames (0 = disabled)
    bool showComparison = false; // Side-by-side view
    bool verbose = false;        // Verbose logging
    bool traceMetalCompute = false; // Log each distinct compute pipeline state the game binds
    bool noisyLighting = false;     // Denoiser "pass" mode: NRD off, noisy lighting shown (comparisons)
};

/**
 * Main configuration
 */
struct Settings {
    bool enabled = true;
    bool ultraPerformance = false; // MetalFX at 3x (the engine's hidden Ultra Performance scale)
    bool frameGeneration = false;  // MetalFX frame interpolation (FrameGen.mm)
    Quality quality = Quality::Quality;
    float ultraScale = 3.0f;      // render scale of ultra_performance (2.0-3.0; the game's is 3.0)
    float textureLodBias = 0.0f;  // added to the game's sampler LOD bias at startup (-0.585 matches 3x)
    float sharpness = 0.0f;       // RCAS after the denoised scaler, 0 (off) to 1
    bool frameWarp = false;       // Warp.mm: re-aim frames to the newest mouse input (with frame generation)
    float gameInputDelayMs = 0;   // Input.mm: wait before the game reads input each frame, 0-30 ms
    Features features;
    Debug debug;
};

/**
 * Get current settings
 */
const Settings& Get();

/**
 * Load settings from config file
 * @param path Path to config.toml
 * @return true if loaded successfully
 */
bool Load(const std::string& path);

/**
 * Load settings from default config locations
 * @return true if loaded successfully
 */
bool Load();

/**
 * Save current settings to file
 * @param path Path to config.toml
 * @return true if saved successfully
 */
bool Save(const std::string& path);

/**
 * Reset to default settings
 */
void Reset();

/**
 * Convert quality enum to string
 */
const char* QualityToString(Quality q);

/**
 * Parse quality from string
 */
Quality QualityFromString(const std::string& s);

} // namespace Config
