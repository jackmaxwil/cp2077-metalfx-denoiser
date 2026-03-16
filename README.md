# MetalFX Denoiser

Replace NVIDIA NRD with Apple MetalFX Temporal Scaler for Cyberpunk 2077 on macOS.

**Status:** Implementation complete — hooks scripted, buffer layout documented, runtime validation pending.

## What it does

Intercepts NRD (Real-time Denoisers) calls via Frida hooks and replaces them with Apple's MetalFX Temporal Scaler for hardware-accelerated denoising of ray-traced effects (diffuse GI, specular, shadows).

## Architecture

Two shared libraries:

1. **MetalFXDenoiser.dylib** — RED4ext plugin (C++): entry point, NRD hooks, Frida exports, config
2. **MetalFXDenoiserCore.dylib** — Metal framework (Objective-C++): MetalFX wrapper, buffer converter, scaler pool

## Prerequisites

- RED4ext installed and functional
- CMake 3.24+, Clang 15+
- macOS 14+ (MetalFX API)

## Build

```bash
mkdir build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
```

## Runtime testing

```bash
# Launch game with RT enabled, then attach Frida
frida -l scripts/metalfx_hooks.js -p <pid>

# Enable replacement
rpc.exports.setReplaceEnabled(true)
```

## Key files

| File | Purpose |
|------|---------|
| `src/plugin/NRDHooks.cpp` | NRD function hooks |
| `src/plugin/FridaIntegration.cpp` | C functions exported for Frida |
| `scripts/metalfx_hooks.js` | Frida hook script (production) |
| `framework/MetalFXDenoiser.mm` | MetalFX wrapper |
| `docs/BUFFER_LAYOUT.md` | NRD struct layouts |
| `docs/STATUS.md` | Project status |

## Related projects

| Project | Description |
|---------|-------------|
| [RED4ext](../RED4ext) | Required mod loader |
| [RED4ext.SDK](../RED4ext.SDK) | SDK dependency |
