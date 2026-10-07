# Pipeline Trace Findings (macOS Cyberpunk 2077)

This document captures the key learnings from the Metal pipeline tracing work used to locate the *actual* denoiser path in the macOS build (where NRD CPU entrypoints never execute).

## Executive summary

- **NRD/RELAX/REBLUR/SIGMA CPU entrypoints are not on the hot path** on macOS (hooks never fire even with RT Psycho / Path Tracing).
- The denoiser work is happening inside **Metal compute pipelines**.
- Pipeline/function names are unreliable (often garbage/NULL when attaching late), so the denoiser must be identified via **resource-binding signatures**.
- A small set of compute PSOs have denoiser-like binding patterns (many textures, ping-pong history buffers, motion/depth, masks).
- We can reliably focus tracing using a **PSO allowlist filter**, which makes high-frequency dispatch tracing feasible.

## What was measured

An earlier, now retired, out-of-process tracing setup replaced Objective-C method implementations (IMP replacement,
which was stable where hooking `objc_msgSend` was not) on the compute command encoder and recorded:

- `setComputePipelineState:`
- `setTexture:atIndex:`
- `setBuffer:offset:atIndex:`
- `setBytes:length:atIndex:`
- `dispatchThreadgroups:threadsPerThreadgroup:` / `dispatchThreads:threadsPerThreadgroup:`

Each dispatch was logged with its texture/buffer/bytes bindings, and each texture with `w/h/pf/usage/storageMode`.
A PSO allowlist cut the noise and overhead enough for per-dispatch tracing. Runs were logged to `runs/<timestamp>/`.
The same measurements are being rebuilt natively in the plugin (`src/plugin/MetalTrace.mm`).

## Key PSO allowlist (current)

Derived empirically by selecting PSOs with high texture/buffer/bytes binding counts.

```
0xa0f0ae100,0xa0f0ad800,0xa0f0af900,0xa0f0ade00,0xa0f0ad500,0xa0f0ad200,0xa0d74b300
```

## Texture metadata decoding

Even when full ObjC bindings are “not available”, we can query texture properties via selector calls using `objc_msgSend`:

- `-[MTLTexture width]`, `-[MTLTexture height]`
- `-[MTLTexture pixelFormat]`
- `-[MTLTexture usage]`
- `-[MTLTexture storageMode]`

This produces stable `texture_info` events and allows identifying motion/depth/history/mask buffers via format + resolution.

### Observed resolution tiers (3440×1440 capture)

- **3440×1440**: full resolution
- **2024×847**: internal aspect-correct intermediate
- **1720×720**: half resolution (exact 0.5× scale)
- **860×360**: quarter resolution

### Observed pixelFormat values (from live captures)

These are values as returned by `-[MTLTexture pixelFormat]`.

- `pf=115`: RGBA16Float (HDR-ish color)
- `pf=65`: RG16Float (motion vectors)
- `pf=25`: R16Float (depth/scalar)
- `pf=13`: R8Unorm (masks)
- `pf=70`: RGBA8Unorm (LDR / utility)
- `pf=30`: RGB10A2Unorm (10-bit HDR)

## Denoiser-candidate PSOs and signatures

### Primary candidate: `PSO 0xa0f0ae100`

This pipeline looks like a “main denoiser” stage based on inputs + history ping-pong + masks.

Representative bindings (from `runs/20260105-210313`):

- Full-res color-like inputs (RGBA16F):
  - `t1`, `t3`, `t4` → **3440×1440 pf=115**
- Motion vectors:
  - `t7` → **2024×847 pf=65**
- Depth/scalar:
  - `t5` → **2024×847 pf=25**
- Full-res masks (ping-pong):
  - `t8`, `t9` → **3440×1440 pf=13** (2 pointers alternating)
- Half-res history / temporal buffers (ping-pong):
  - `t15`, `t16` → **1720×720 pf=25** (alternating)
- Additional half-res outputs:
  - `t12` → **1720×720 pf=30**
  - `t13`, `t14` → **1720×720 pf=115**
- Quarter-res utility:
  - `t11` → **860×360 pf=70**

### Secondary candidate: `PSO 0xa0f0ad800`

Also strongly denoiser-like (high binding counts, multiple ping-pong pairs at half-res):

- Full-res color-like textures: `t1`, `t3` (3440×1440 pf=115)
- Motion vectors: `t2` (2024×847 pf=65)
- Multiple half-res ping-pong pairs:
  - `t4..t7` (1720×720 pf=25 alternating)
  - `t12..t14` (1720×720 pf=25/pf=23 alternating)
- Half-res HDR intermediates: `t15`, `t16` (1720×720 pf=115)

### Temporal stage candidate: `PSO 0xa0f0af900`

This looks like a half-res temporal/history stage:

- Inputs: motion + depth (`t0` pf=65, `t1` pf=25 at 2024×847)
- Multiple half-res ping-pong pairs at `t2..t6` (1720×720 pf=25/pf=23 alternating)

## Recommended next steps (to finish RT performance optimization)

### 1) Confirm output role per PSO (read vs write)

Goal: identify which slot(s) are the “final” denoised output for each candidate PSO.

- Add/extend tracing to infer outputs:
  - Track ping-pong pairs and correlate with subsequent passes.
  - Preferably also capture `setTexture:atIndex:` *and* `useResource(s):usage:` / `memoryBarrierWithResources:` if available to infer write targets.

Deliverable: a stable mapping like:

| PSO | output slot(s) | history slot(s) | motion slot | depth slot |
|---|---|---|---|---|

### 2) Replace-by-PSO (prototype “skip & measure”)

Before implementing MetalFX replacement, validate each candidate PSO’s contribution:

- Add an experimental mode: **skip dispatches** for a single PSO (or reduce dispatch count) and measure:
  - FPS change
  - image artifact type
  - whether RT noise reappears

This quickly confirms which PSO is the true denoiser bottleneck.

### 3) Integrate MetalFX replacement at the Metal compute level (not NRD CPU)

Given macOS doesn’t call NRD CPU entrypoints, the replacement should hook at Metal compute dispatch time:

- For the identified denoiser PSO(s):
  - Collect the required textures (color, motion, depth, history, exposure/masks if used).
  - Run MetalFX Temporal Scaler (or your denoiser compute path) to produce the expected output(s).
  - Route outputs back into the same texture(s) the game expects.
  - Then either:
    - skip the original dispatch, or
    - allow it but overwrite its output (worse perf).

### 4) Lock down slot-to-semantic mapping and make it configuration-driven

Once the slot mapping is stable:

- Add a config section keyed by PSO pointer:
  - which `t#` is input/output/motion/depth/history
  - motion vector space (NDC vs pixels, Y-flip)
  - resolution scale assumptions

This will make the mod resilient across patches where PSO pointers may change.

### 5) Performance hardening

- Keep PSO allowlist enabled by default when tracing.
- Disable all event emission by default; sample only when requested.
- Keep all hot-path work in the native plugin (Objective-C++/C++); the replacement hook lives there.

### 6) Final validation workflow

- A/B compare (replacement toggled via config):
  - baseline vs replacement
  - per-feature (GI/shadows/reflections) scenarios
- Record:
  - FPS, GPU timing, fallback counters
  - screenshot diffs at fixed camera positions

## Reference runs

- `runs/20260105-210144`: allowlist filter verified (only 7 PSOs emitting)
- `runs/20260105-210313`: texture metadata + binding signatures (26 textures)
- `runs/20260105-210752`: texture_info includes usage/storageMode
