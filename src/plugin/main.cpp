/**
 * @file main.cpp
 * @brief MetalFX Denoiser RED4ext plugin entry point
 *
 * Replaces the game's ray tracing denoiser (NRD RELAX) and MetalFX upscaler with Apple's MetalFX temporal
 * denoised scaler (Denoise.mm), through Metal method hooks (MetalTrace.mm). Switched by config.toml ([metalfx]
 * enabled, [debug] noisy_lighting) and by ModMenu (MetalFX Denoiser page); METALFX_DENOISE=off|pass|fx (tests) wins
 * over both.
 */

#include <RED4ext/RED4ext.hpp>
#include <atomic>
#include <cstdlib>
#include <dlfcn.h>
#include <sstream>

#include "Config.hpp"
#include "Denoise.hpp"
#include "Logger.hpp"
#include "MetalTrace.hpp"
#include "modmenu_api.h" // copy of ModMenu's include/modmenu/modmenu_api.h

static bool g_initialized = false;

extern "C" __attribute__((visibility("default"))) bool ModMenu_Register(const ModMenuApi* api);

namespace MetalFXDenoiser {

// The player's choice: the denoiser on, and the debug view of the noisy lighting.
std::atomic<bool> s_denoiser{false}, s_noisy{false}, s_menuRegistered{false};

void ApplyMode()
{
    if (const char* env = std::getenv("METALFX_DENOISE"); env && *env) { // tests set the mode themselves
        return;
    }
    Denoise::SetMode(s_noisy.load() ? "pass" : s_denoiser.load() ? "fx" : "off");
}

void OnDenoiserToggle(const ModMenuEntryPath*, bool on)
{
    s_denoiser.store(on);
    ApplyMode();
}

void OnNoisyToggle(const ModMenuEntryPath*, bool on)
{
    s_noisy.store(on);
    ApplyMode();
}

bool Initialize()
{
    if (g_initialized) {
        return true;
    }

    Logger::Initialize();
    Logger::Info("Initializing MetalFX Denoiser v1.1.0");

    Config::Load();
    const auto& config = Config::Get();
    {
        std::ostringstream os;
        os << "Config loaded: enabled=" << (config.enabled ? "yes" : "no")
           << " traceMetalCompute=" << (config.debug.traceMetalCompute ? "yes" : "no");
        Logger::Info(os.str());
    }

    // The denoiser runs in the Metal hooks; so does the research tracer ([debug] trace_metal_compute, METALFX_TRACE=1).
    s_denoiser.store(config.enabled);
    s_noisy.store(config.debug.noisyLighting);
    const bool denoiser = Denoise::Supported();
    if (denoiser) {
        ApplyMode();
    } else {
        Logger::Warn("MetalFX temporal denoised scaler not available (needs macOS 26 on a supported Mac): denoiser off");
    }
    const char* traceEnv = std::getenv("METALFX_TRACE");
    if (denoiser || config.debug.traceMetalCompute || (traceEnv && traceEnv[0] == '1')) {
        MetalTrace::Install();
    }
    if (denoiser) {
        // ModMenu calls ModMenu_Register itself if it loaded first; otherwise register here.
        using GetApi = const ModMenuApi* (*)();
        if (auto getApi = reinterpret_cast<GetApi>(dlsym(RTLD_DEFAULT, "ModMenu_GetApi"))) {
            ModMenu_Register(getApi());
        }
    }

    // Fail closed: no C++ hooks (no NRD entry point has a verified address DB entry, and they do not run on macOS).
    g_initialized = true;
    Logger::Info(std::string("Initialization complete: denoiser ") +
                 (!denoiser ? "unavailable" : s_noisy.load() ? "debug noisy lighting" : s_denoiser.load() ? "on" : "off"));
    return true;
}

void Shutdown()
{
    if (!g_initialized) {
        return;
    }

    MetalTrace::Uninstall();

    g_initialized = false;
    Logger::Info("Shutdown complete");
    Logger::Shutdown();
}

} // namespace MetalFXDenoiser

// ModMenu page: the denoiser switch and the noisy-lighting debug view. ModMenu saves both; a saved value that differs
// from config.toml's is applied through the callbacks right after registration.
extern "C" __attribute__((visibility("default"))) bool ModMenu_Register(const ModMenuApi* api)
{
    if (!api || !Denoise::Supported() || MetalFXDenoiser::s_menuRegistered.exchange(true)) {
        return false;
    }
    const ModMenuModInfo mod = {.modId = {"MetalFXDenoiser"}, .name = {"MetalFX Denoiser"}, .version = {"1.1"}};
    const ModMenuPageInfo page = {.pageId = {"main"}, .title = {"Ray tracing"}};
    const ModMenuToggleInfo denoiser = {.entryId = {"apple_denoiser"},
                                        .title = {"Apple MetalFX denoiser (RT and path tracing, MetalFX upscaling)"},
                                        .defaultValue = MetalFXDenoiser::s_denoiser.load(),
                                        .onChanged = &MetalFXDenoiser::OnDenoiserToggle};
    const ModMenuToggleInfo noisy = {.entryId = {"noisy_lighting"},
                                     .title = {"Debug: noisy lighting (no denoiser)"},
                                     .defaultValue = MetalFXDenoiser::s_noisy.load(),
                                     .onChanged = &MetalFXDenoiser::OnNoisyToggle};
    const bool ok = api->RegisterMod(&mod) && api->RegisterPage("MetalFXDenoiser", &page) &&
                    api->RegisterToggle("MetalFXDenoiser", "main", &denoiser) &&
                    api->RegisterToggle("MetalFXDenoiser", "main", &noisy);
    Logger::Info(ok ? "ModMenu page registered" : "ModMenu registration failed");
    return ok;
}

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle, RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    switch (aReason) {
    case RED4ext::v1::EMainReason::Load:
        return MetalFXDenoiser::Initialize();
    case RED4ext::v1::EMainReason::Unload:
        MetalFXDenoiser::Shutdown();
        return true;
    }
    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"MetalFX Denoiser";
    aInfo->author = L"Cyberpunk 2077 macOS Modding Community";
    aInfo->version = RED4EXT_V1_SEMVER(1, 1, 0);
    // Uses no game addresses, so it does not depend on the runtime version.
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1;
}
