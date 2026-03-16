# MetalFX Denoiser — Buffer Layout Reference

> **Last updated:** 2026-02-21
> **Status:** Partial — offsets are heuristic, pending runtime validation

## Overview

The MetalFX denoiser replaces NRD (NVIDIA Real-time Denoisers) calls with Apple MetalFX Temporal Scaler. To do so, we must extract the following from game buffers:

1. **Color texture** (noisy RT input)
2. **Output texture** (denoised result)
3. **Motion vectors** (per-pixel screen-space motion)
4. **Depth buffer** (per-pixel depth)
5. **Command buffer** (active Metal command buffer)
6. **Jitter** (TAA subpixel jitter X/Y)
7. **Camera cut signal** (history reset flag)

## NRD Function Signatures (ARM64)

### REBLUR_Diffuse (3 args)

```
void REBLUR_Diffuse(void* denoiserState, void* inputBuffer, void* outputBuffer)
```

- `x0` — denoiser state struct (contains command buffer reference)
- `x1` — input buffer wrapper (contains MTLTexture for noisy color)
- `x2` — output buffer wrapper (contains MTLTexture for denoised result)

### REBLUR_DiffuseSpecular (5 args)

```
void REBLUR_DiffuseSpecular(void* state, void* diffIn, void* specIn, void* diffOut, void* specOut)
```

- `x0` — denoiser state
- `x1` — diffuse input
- `x2` — specular input
- `x3` — diffuse output
- `x4` — specular output

### SIGMA_Shadow (3 args)

```
void SIGMA_Shadow(void* filterState, void* shadowInput, void* shadowOutput)
```

### NrdInputs (config struct)

```
void NrdInputs_Configure(void* nrdInputsStruct)
```

- `x0` — pointer to NrdInputs struct

## Buffer Wrapper Layout (Heuristic)

Game buffers passed to NRD are not raw `MTLTexture` pointers. They are wrapper structs. `BufferInterceptor::ExtractBuffer` tries these offsets:

| Offset | Interpretation | Confidence |
|--------|---------------|------------|
| `+0x00` | Direct pointer (if wrapper IS the texture) | Low |
| `+0x10` | Common render target wrapper | Medium |
| `+0x30` | Alternate wrapper layout | Medium |

The extraction uses `mach_vm_read_overwrite` for safe reads and checks for valid Objective-C object signatures (non-null isa pointer).

## NrdInputs Struct Layout (Heuristic)

From `MetalFX_OnNrdInputsConfigured` hex dump analysis:

| Offset Range | Field (guess) | Evidence |
|-------------|---------------|----------|
| `+0x00..+0x0F` | Flags / mode | — |
| `+0x10..+0x17` | Jitter X, Y (float pair) | Values in -0.5..0.5 range |
| `+0x18..+0x1F` | Resolution W, H (uint32 pair) | Values 640..8192 |
| `+0x20..+0x2F` | Camera data | — |

The heuristic dimension scan in `FridaIntegration.cpp` searches for plausible `uint32` width/height pairs (640-8192 range) at 4-byte intervals.

## Command Buffer Extraction

The denoiser state (`x0` in NRD calls) contains a reference to the active `MTLCommandBuffer`. The auto-probe scans offsets `+0x00..+0x80` at 8-byte intervals for pointers that look like Objective-C objects (non-null isa pointer).

## Motion Vectors and Depth

These are NOT passed directly to NRD functions. They must be captured from earlier in the render pipeline. Strategies:

1. **NrdInputs struct** — may contain pointers to motion/depth textures
2. **Render node hooks** — `FilterOutput` at `0xFEDE44` processes render node output and may reference the textures
3. **Pipeline trace** — the debug Frida script has Metal pipeline tracing that can identify texture creation patterns

## Resource Flow

```
Game Render Pipeline
    │
    ├── Creates motion vectors texture
    ├── Creates depth buffer texture
    ├── Creates color (noisy) textures
    │
    └── NRD Denoiser Calls
         ├── REBLUR_Diffuse(state, colorIn, colorOut)
         ├── REBLUR_DiffuseSpecular(state, diffIn, specIn, diffOut, specOut)
         └── SIGMA_Shadow(state, shadowIn, shadowOut)
              │
              └── MetalFX hooks intercept here
                   ├── Extract textures from buffer wrappers
                   ├── Get motion/depth from captured resources
                   ├── Get cmd buffer from denoiser state
                   └── Call MetalFX_Denoise()
```

## Validation Steps

1. Run `frida -l metalfx_hooks.debug.js -f Cyberpunk2077` with RT enabled
2. Check `[MetalFX] NrdInputs first 128 bytes:` hex dump
3. Look for jitter values at offsets `+0x10..+0x20`
4. Look for resolution values at `+0x18..+0x20`
5. Check `probeForCommandBuffer` auto-detect messages
6. Verify `ExtractBuffer` finds valid MTLTexture pointers

## Known Unknowns

- Exact motion vector format (NDC screen-space vs pixel-space)
- Whether motion vectors need Y-flip for MetalFX
- Exact offset of command buffer in denoiser state
- Whether depth is linear or reverse-Z
- Buffer wrapper struct definition (no headers available)
