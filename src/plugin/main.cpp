/**
 * @file main.cpp
 * @brief MetalFX Denoiser RED4ext plugin entry point
 *
 * Research prototype: aims to replace the game's ray-tracing denoiser with Apple MetalFX.
 * On macOS the NRD CPU entry points never execute (docs/PIPELINE_TRACE_FINDINGS.md); the denoiser
 * runs as Metal compute pipelines. The plugin currently only traces compute pipeline binds
 * (opt-in) and does not change rendering.
 */

#include <RED4ext/RED4ext.hpp>
#include <sstream>

#include "Config.hpp"
#include "Logger.hpp"
#include "MetalBridge.h"
#include "MetalTrace.hpp"

static MetalFXContext* g_metalFXContext = nullptr;
static bool g_initialized = false;

namespace MetalFXDenoiser {

bool Initialize()
{
    if (g_initialized) {
        return true;
    }

    Logger::Initialize();
    Logger::Info("Initializing MetalFX Denoiser v1.0.0");

    Config::Load();
    const auto& config = Config::Get();
    {
        std::ostringstream os;
        os << "Config loaded: enabled=" << (config.enabled ? "yes" : "no")
           << " traceMetalCompute=" << (config.debug.traceMetalCompute ? "yes" : "no");
        Logger::Info(os.str());
    }

    if (!config.enabled) {
        Logger::Warn("Plugin disabled in config");
        return true;
    }

    if (!MetalFX_IsSupported()) {
        Logger::Error("MetalFX not supported on this system (requires macOS 13+ on Apple silicon)");
        return false;
    }

    g_metalFXContext = MetalFX_CreateContext(nullptr);
    if (!g_metalFXContext) {
        Logger::Error("Failed to create MetalFX context");
        return false;
    }

    // Fail closed: C++ hooks go through RED4ext's hooking API with addresses from the verified address DB only.
    // No NRD entry point has a verified entry (and they do not run on macOS), so none are attached.
    Logger::Info("NRD CPU hooks disabled: no verified address DB entries");

    if (config.debug.traceMetalCompute) {
        MetalTrace::Install();
    }

    g_initialized = true;
    Logger::Info("Initialization complete (no rendering changes are made yet)");
    return true;
}

void Shutdown()
{
    if (!g_initialized) {
        return;
    }

    MetalTrace::Uninstall();

    if (g_metalFXContext) {
        MetalFX_DestroyContext(g_metalFXContext);
        g_metalFXContext = nullptr;
    }

    g_initialized = false;
    Logger::Info("Shutdown complete");
    Logger::Shutdown();
}

} // namespace MetalFXDenoiser

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::PluginHandle aHandle, RED4ext::EMainReason aReason,
                                        const RED4ext::Sdk* aSdk)
{
    switch (aReason) {
    case RED4ext::EMainReason::Load:
        return MetalFXDenoiser::Initialize();
    case RED4ext::EMainReason::Unload:
        MetalFXDenoiser::Shutdown();
        return true;
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::PluginInfo* aInfo)
{
    aInfo->name = L"MetalFX Denoiser";
    aInfo->author = L"Cyberpunk 2077 macOS Modding Community";
    aInfo->version = RED4EXT_SEMVER(1, 0, 0);
    // Uses no game addresses, so it does not depend on the runtime version.
    aInfo->runtime = RED4EXT_RUNTIME_INDEPENDENT;
    aInfo->sdk = RED4EXT_SDK_LATEST;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_LATEST;
}
