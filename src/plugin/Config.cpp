/**
 * @file Config.cpp
 * @brief Configuration loading and management
 */

#include "Config.hpp"
#include "Logger.hpp"
#include <fstream>
#include <iostream>
#include <sstream>
#include <algorithm>
#include <cctype>

namespace Config {

// Global settings instance
static Settings s_settings;

// Helper to trim whitespace
static std::string Trim(const std::string& str) {
    size_t start = str.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return "";
    size_t end = str.find_last_not_of(" \t\r\n");
    return str.substr(start, end - start + 1);
}

// Helper to lowercase
static std::string ToLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), 
                   [](unsigned char c){ return std::tolower(c); });
    return s;
}

// Helper to parse bool
static bool ParseBool(const std::string& value) {
    std::string v = ToLower(Trim(value));
    return v == "true" || v == "1" || v == "yes" || v == "on";
}

// Helper to parse int
static int ParseInt(const std::string& value) {
    try {
        return std::stoi(Trim(value));
    } catch (...) {
        return 0;
    }
}

// Helper to parse float
static float ParseFloat(const std::string& value) {
    try {
        return std::stof(Trim(value));
    } catch (...) {
        return 0.0f;
    }
}

const Settings& Get() {
    return s_settings;
}

bool Load() {
    if (Load(std::string("red4ext/plugins/MetalFXDenoiser/config.toml"))) {
        return true;
    }
    if (Load(std::string("config/config.toml"))) {
        return true;
    }
    return false;
}

bool Load(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        Logger::Warn(std::string("Failed to open config: ") + path);
        return false;
    }
    
    std::string line;
    std::string currentSection;
    
    while (std::getline(file, line)) {
        line = Trim(line);
        
        // Skip empty lines and comments
        if (line.empty() || line[0] == '#') {
            continue;
        }
        
        // Section header
        if (line[0] == '[' && line.back() == ']') {
            currentSection = ToLower(line.substr(1, line.size() - 2));
            continue;
        }
        
        // Key-value pair
        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            continue;
        }
        
        std::string key = ToLower(Trim(line.substr(0, eq)));
        std::string value = Trim(line.substr(eq + 1));
        
        // Remove quotes from string values
        if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
            value = value.substr(1, value.size() - 2);
        }
        
        // Parse based on section
        if (currentSection == "metalfx") {
            if (key == "enabled") {
                s_settings.enabled = ParseBool(value);
            } else if (key == "ultra_performance") {
                s_settings.ultraPerformance = ParseBool(value);
            } else if (key == "frame_generation") {
                s_settings.frameGeneration = ParseBool(value);
            } else if (key == "dynamic_scale_fps") {
                s_settings.dynamicScaleFps = ParseFloat(value);
            } else if (key == "frame_generation_multiplier") {
                s_settings.frameGenerationMultiplier = value == "4" ? 4 : 2;
            } else if (key == "quality") {
                s_settings.quality = QualityFromString(value);
            } else if (key == "ultra_scale") {
                s_settings.ultraScale = ParseFloat(value);
            } else if (key == "texture_lod_bias") {
                s_settings.textureLodBias = ParseFloat(value);
            } else if (key == "sharpness") {
                s_settings.sharpness = ParseFloat(value);
            }
        } else if (currentSection == "features") {
            if (key == "shadows") {
                s_settings.features.shadows = ParseBool(value);
            } else if (key == "rtxdi_diffuse") {
                s_settings.features.rtxdiDiffuse = ParseBool(value);
            } else if (key == "rtxdi_specular") {
                s_settings.features.rtxdiSpecular = ParseBool(value);
            } else if (key == "restir_gi") {
                s_settings.features.restirGI = ParseBool(value);
            } else if (key == "reflections") {
                s_settings.features.reflections = ParseBool(value);
            } else if (key == "ao") {
                s_settings.features.ao = ParseBool(value);
            }
        } else if (currentSection == "debug") {
            if (key == "log_performance") {
                s_settings.debug.logPerformance = ParseInt(value);
            } else if (key == "show_comparison") {
                s_settings.debug.showComparison = ParseBool(value);
            } else if (key == "verbose") {
                s_settings.debug.verbose = ParseBool(value);
            } else if (key == "trace_metal_compute") {
                s_settings.debug.traceMetalCompute = ParseBool(value);
            } else if (key == "noisy_lighting") {
                s_settings.debug.noisyLighting = ParseBool(value);
            }
        }
    }
    
    Logger::Info(std::string("Loaded settings from: ") + path);
    
    return true;
}

bool Save(const std::string& path) {
    std::ofstream file(path);
    if (!file.is_open()) {
        Logger::Warn(std::string("Failed to write config: ") + path);
        return false;
    }
    
    file << "# MetalFX Denoiser Configuration\n";
    file << "# Generated automatically\n\n";
    
    file << "[metalfx]\n";
    file << "enabled = " << (s_settings.enabled ? "true" : "false") << "\n";
    file << "quality = \"" << QualityToString(s_settings.quality) << "\"\n";
    file << "sharpness = " << s_settings.sharpness << "\n\n";
    
    file << "[features]\n";
    file << "shadows = " << (s_settings.features.shadows ? "true" : "false") << "\n";
    file << "rtxdi_diffuse = " << (s_settings.features.rtxdiDiffuse ? "true" : "false") << "\n";
    file << "rtxdi_specular = " << (s_settings.features.rtxdiSpecular ? "true" : "false") << "\n";
    file << "restir_gi = " << (s_settings.features.restirGI ? "true" : "false") << "\n";
    file << "reflections = " << (s_settings.features.reflections ? "true" : "false") << "\n";
    file << "ao = " << (s_settings.features.ao ? "true" : "false") << "\n\n";
    
    file << "[debug]\n";
    file << "log_performance = " << s_settings.debug.logPerformance << "\n";
    file << "show_comparison = " << (s_settings.debug.showComparison ? "true" : "false") << "\n";
    file << "verbose = " << (s_settings.debug.verbose ? "true" : "false") << "\n";
    file << "trace_metal_compute = " << (s_settings.debug.traceMetalCompute ? "true" : "false") << "\n";
    
    return true;
}

void Reset() {
    s_settings = Settings{};
}

const char* QualityToString(Quality q) {
    switch (q) {
        case Quality::Performance: return "performance";
        case Quality::Balanced: return "balanced";
        case Quality::Quality: return "quality";
        default: return "quality";
    }
}

Quality QualityFromString(const std::string& s) {
    std::string lower = ToLower(s);
    if (lower == "performance") return Quality::Performance;
    if (lower == "balanced") return Quality::Balanced;
    return Quality::Quality;
}

} // namespace Config
