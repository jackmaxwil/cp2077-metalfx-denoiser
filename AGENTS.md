# MetalFX Denoiser Mod - Agent Guidelines

## Project Context

This mod replaces NVIDIA NRD (Real-time Denoisers) with Apple's MetalFX Temporal Scaler for Cyberpunk 2077 on macOS. It provides hardware-accelerated denoising for ray tracing features.

## Current Status (Canonical)

See `docs/STATUS.md` and `docs/DEVELOPMENT.md` for the up-to-date project status and next steps.

## Architecture

The mod consists of two shared libraries:

1. **MetalFXDenoiser.dylib** - RED4ext plugin (C++)
   - Entry point: `src/plugin/main.cpp`
   - NRD hooks: `src/plugin/NRDHooks.cpp`
   - Buffer extraction: `src/plugin/BufferInterceptor.cpp`
   - Configuration: `src/plugin/Config.cpp`

2. **MetalFXDenoiserCore.dylib** - Metal framework (Objective-C++)
   - C bridge: `framework/MetalBridge.h`
   - Denoiser wrapper: `framework/MetalFXDenoiser.mm`
   - Scaler pool: `framework/TemporalScalerPool.mm`
   - Buffer converter: `framework/BufferConverter.mm`

## Key Addresses (Game v2.21)

Located in `lib/Support/macOS/AddressResolverOverride.hpp`:

| Function | Offset | Purpose |
|----------|--------|---------|
| REBLUR_Diffuse | 0xF5A408 | Diffuse GI |
| REBLUR_DiffuseSpecular | 0xF6AFA0 | Combined |
| SIGMA_Shadow | 0xF7901C | Shadows |
| NrdInputs | 0xFEF864 | Config |

## Development

### Building

```bash
mkdir build && cd build
cmake ..
make -j8
```

### Updating Addresses

After game updates:
```bash
python3 scripts/discover_nrd_addresses.py
```

### Testing

1. Copy dylibs to `red4ext/plugins/MetalFXDenoiser/`
2. Launch game via RED4ext
3. Check logs for hook activation

## Current Status

- [x] Address discovery complete
- [x] Plugin infrastructure complete  
- [x] MetalFX wrapper complete
- [ ] Runtime hook installation (needs Frida)
- [ ] Buffer structure reverse engineering
- [ ] Integration testing

## Code Standards

- C++20 for plugin code
- Objective-C++ for Metal framework
- Use `std::cerr` for logging (no spdlog dependency)
- Follow existing naming conventions
