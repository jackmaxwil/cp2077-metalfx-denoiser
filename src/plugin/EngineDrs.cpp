#include "EngineDrs.hpp"

#include "Fnv1a.hpp"
#include "Logger.hpp"

#include <RED4ext/RED4ext.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>

namespace {

// DRS::Update's state (inside the per-view frame context at +0x2c; layout from the binary, docs/DRS_RECON.md 3.1).
struct State {
    uint32_t w, h, prevW, prevH, maxW, minW, maxH, minH, outW, outH, window, skip;
    float sum;
    uint32_t count;
    uint8_t fixed; // a size forced by the engine's override setter: left alone
};
static_assert(offsetof(State, outW) == 0x20 && offsetof(State, fixed) == 0x38);

using UpdateFn = void (*)(State*, uint64_t, uint64_t, void*);
UpdateFn o_update = nullptr;
uint8_t* const* g_renderer = nullptr; // address DB "Renderer/Global" (verified): the renderer, upscalers at +0x7670..
std::atomic<bool> g_active{false};
std::atomic<float> g_scale{0}, g_sharpest{0};
uint64_t g_frames = 0; // render thread only

void H_update(State* s, uint64_t outLo, uint64_t outHi, void* ctx)
{
    o_update(s, outLo, outHi, ctx);
    // Dynamic: min below max, inside the output, no override (the fixed path sets min = max).
    const bool active = !s->fixed && s->outW && s->outH && s->minH && s->minH < s->maxH && s->maxH <= s->outH &&
                        s->maxW <= s->outW;
    if (g_active.exchange(active) != active || (active && ++g_frames % 1800 == 0)) {
        char buf[200];
        std::snprintf(buf, sizeof(buf), "Engine DRS: %s, render %ux%u, range %ux%u..%ux%u, output %ux%u, scale %.2f",
                      active ? "on" : "off", s->w, s->h, s->minW, s->minH, s->maxW, s->maxH, s->outW, s->outH,
                      g_scale.load());
        Logger::Info(buf);
    }
    const float scale = g_scale.load(std::memory_order_relaxed);
    if (!active || scale < 1.0f) {
        return;
    }
    // MetalFX's dynamic mode (upscaler +0x1a): the engine's node then keeps one scaler with content properties and
    // copies each frame's content rectangle into it, so a size change keeps the history and creates nothing. The
    // engine sets it only for a viewport quality no menu value reaches; set it with a recreate request (+0x1b), once
    // per change. Only when the upscaler looks like MetalFX's state: enabled (+0x19) and a quality 0-5 at +0x0.
    if (g_renderer && *g_renderer) {
        uint8_t* mfx = *reinterpret_cast<uint8_t* const*>(*g_renderer + 0x7680);
        if (mfx && mfx[0x19] == 1 && *reinterpret_cast<const uint32_t*>(mfx) <= 5 && mfx[0x1a] != 1) {
            mfx[0x1a] = 1;
            mfx[0x1b] = 1;
            Logger::Info("Engine DRS: MetalFX dynamic mode on");
        }
    }
    // Floor at 3x: MetalFX takes content scales 1-3 on this hardware, and the engine passes out/minW as the scaler's
    // maximum content scale (a changed range recreates the scaler once). Only the floor moves; the maximum is the
    // allocation and is never raised.
    const uint32_t floorW = (s->outW + 2) / 3, floorH = (s->outH + 2) / 3;
    if (s->minH > floorH) {
        s->minW = floorW;
        s->minH = floorH;
    }
    // Ceiling at the sharpest scale we use: render targets and MetalFX's dynamic scaler are allocated at the maximum,
    // and at the player's DRS maximum of 100% that is native size (about 2 ms more per frame at 3x, measured).
    if (const float sharpest = g_sharpest.load(std::memory_order_relaxed); sharpest >= 1.0f) {
        const auto capW = static_cast<uint32_t>(std::ceil(s->outW / sharpest)),
                   capH = static_cast<uint32_t>(std::ceil(s->outH / sharpest));
        if (capH >= s->minH && capW >= s->minW) {
            s->maxW = std::min(s->maxW, capW);
            s->maxH = std::min(s->maxH, capH);
        }
    }
    const auto h = std::clamp(static_cast<uint32_t>(std::lround(s->outH / std::min(scale, 3.0f))) & ~1u, s->minH,
                              s->maxH);
    s->h = h;
    s->w = std::clamp(static_cast<uint32_t>(std::lround(static_cast<double>(h) * s->outW / s->outH)), s->minW, s->maxW);
}

} // namespace

namespace EngineDrs {

void Attach(void* handle, const void* opaque)
{
    const auto* sdk = static_cast<const RED4ext::v1::Sdk*>(opaque);
    const auto address = RED4ext::UniversalRelocBase::Resolve(Fnv1a32("DRS/Update"));
    if (!address || !sdk || !sdk->hooking) {
        Logger::Warn("Engine DRS: DRS/Update is not a verified entry in the address DB; not hooked");
        return;
    }
    // The function starts with sub sp, sp, #0x80 (2.3.1); anything else means another build: fail closed.
    if (*reinterpret_cast<const uint32_t*>(address) != 0xD10203FFu) {
        Logger::Warn("Engine DRS: unexpected prologue at DRS/Update; not hooked");
        return;
    }
    g_renderer = reinterpret_cast<uint8_t* const*>(RED4ext::UniversalRelocBase::Resolve(Fnv1a32("Renderer/Global")));
    const bool ok = sdk->hooking->Attach(static_cast<RED4ext::v1::PluginHandle>(handle), reinterpret_cast<void*>(address),
                                         reinterpret_cast<void*>(&H_update), reinterpret_cast<void**>(&o_update));
    Logger::Info(ok ? "Engine DRS: hooked" : "Engine DRS: hook failed");
}

bool Active()
{
    return g_active.load(std::memory_order_relaxed);
}

void SetScale(float scale, float sharpest)
{
    g_sharpest.store(sharpest >= 1.0f ? std::min(sharpest, 3.0f) : 0.0f);
    g_scale.store(scale >= 1.0f ? std::min(scale, 3.0f) : 0.0f);
}

} // namespace EngineDrs
