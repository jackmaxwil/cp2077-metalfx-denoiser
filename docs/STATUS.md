# MetalFX Denoiser — Status

> **Last updated:** 2026-02-21
> **Target game build:** Cyberpunk 2077 macOS **v2.3.1**
> **Target arch:** Apple Silicon (arm64)
> **Status:** Implementation complete, runtime validation pending

## What's complete

- **Address discovery**: NRD function addresses found (REBLUR_Diffuse, REBLUR_DiffuseSpecular, SIGMA_Shadow, NrdInputs)
- **Plugin infrastructure**: RED4ext plugin builds cleanly, config system, logging
- **MetalFX wrapper**: TemporalScalerPool, BufferConverter, C bridge API
- **Frida hook scripts**: `metalfx_hooks.js` with auto-capture (jitter, command buffer, textures)
- **Debug tooling**: `metalfx_hooks.debug.js` for buffer inspection and NRD struct dumping
- **Buffer layout documentation**: `docs/BUFFER_LAYOUT.md` with NRD struct layouts and extraction strategy

## Runtime validation checklist

- [ ] Launch with RT enabled, attach Frida, verify NRD hooks fire
- [ ] Confirm NrdInputs jitter extraction (auto-probe at offsets 0x10-0x30)
- [ ] Confirm command buffer auto-capture from denoiser state
- [ ] Enable replacement mode, verify MetalFX denoise output
- [ ] FPS comparison: NRD vs MetalFX (target: measurable improvement)

## Key files

| File | Purpose |
|------|---------|
| `src/plugin/main.cpp` | Plugin entry point |
| `src/plugin/NRDHooks.cpp` | NRD function hooks |
| `src/plugin/FridaIntegration.cpp` | C functions exported for Frida |
| `src/plugin/Config.cpp` | Runtime configuration |
| `scripts/metalfx_hooks.js` | Frida hook script (production) |
| `scripts/metalfx_hooks.debug.js` | Debug instrumentation |
| `framework/MetalBridge.h` | C bridge to Metal framework |
| `framework/MetalFXDenoiser.mm` | MetalFX wrapper |
| `docs/BUFFER_LAYOUT.md` | NRD struct layouts |

## Canonical docs

- **Development guide:** `docs/DEVELOPMENT.md`
- **Addresses:** `docs/ADDRESSES.md`
- **Buffer layout:** `docs/BUFFER_LAYOUT.md`

## After a game update

1. Run address discovery: `python3 scripts/discover_nrd_addresses.py`
2. Update `lib/Support/macOS/AddressResolverOverride.hpp` and `scripts/metalfx_hooks.js`
3. Rebuild and validate per `docs/DEVELOPMENT.md`
