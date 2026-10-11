# Dynamic resolution scaling: recon and proposals

> **Date:** 2026-10-10
> **Target:** Cyberpunk 2077 2.3.1, macOS arm64 binary. Image base 0x100000000; for `__TEXT`, VM = base + file offset.
> **Machine:** M4 Max, macOS 26.7.1.
> **Scope:** how the engine picks the render size (its dynamic resolution, "DRS"), how that size reaches MetalFX, what this
> plugin does on top (`ultra_scale`, `dynamic_scale_fps`, the Apple denoiser, frame generation), and what to change to make
> a dynamic render size around MetalFX Performance (2x, 50%) look like a fixed one.

Everything here is static analysis of the shipping binary, plus three runtime facts: the plugin's own log, one MetalFX
API query on this Mac, and earlier measurements quoted from STATUS.md. Items that still need a runtime check are marked
**(verify)**.

> **Correction (2026-10-10, measured):** the engine's DRS is switched on by the hidden `DynamicResolutionScaling`
> setting, not by MetalFX "Dynamic", and on its own it still makes a new MetalFX scaler per size (no content
> properties): finding 2 below holds only with MetalFX's dynamic mode (`renderer+0x7680` +0x1a), which no menu value
> sets. The plugin now sets it (EngineDrs.cpp; STATUS.md, "Dynamic scale on the engine's dynamic resolution").

## 1. Summary

**Findings**

1. **How the engine's DRS works.**
   - It is a small, fast proportional controller (`0x1010cd188`, called once per view setup from `0x1010cd56c`).
   - It works on the **render height in lines**; the width follows from the aspect ratio.
   - It decides every **4 frames** (`DRS/MinNumFrames`), moves in **8-line** steps (`DRS/StepSize`), and ignores the
     **2 frames** after each change (`DRS/FramesToSkip`).
   - It goes down at 24 lines per ms over the target and up at 8 lines per ms under it.
   - 11 hidden config variables drive it (`DRS/*`, §3.3). The game's menu exposes none of them.
2. **Real DRS does not reallocate or rebuild anything.**
   - Only MetalFX quality **"Dynamic"** turns it on.
   - Render targets are then sized for the maximum, and each frame renders into a top-left content rectangle.
   - The MetalFX scaler is created once with `inputContentPropertiesEnabled = YES`, `inputContentMinScale = out/maxW`
     and `inputContentMaxScale = out/minW`. The content size is set every frame (`0x101c34c18`).
   - So a DRS step costs nothing and keeps the upscaler's history.
3. **This plugin's dynamic scale takes the slow road.**
   - `dynamic_scale_fps` rewrites the fixed scale table (`Upscaler/ScaleTable`). The engine treats that as a new
     *fixed* size: every render-size resource is reallocated, and MetalFX is recreated because the texture size no
     longer matches the scaler (`0x101c34c18`, its recreate checks).
   - Result: the measured 147-172 ms hitch, about a second of slow frames, and a history reset on every step.
4. **The plugin's Apple denoiser and frame generation ignore the content rectangle.**
   - `Denoise::EncodeScaler` hands the denoised scaler the whole input texture (`Denoise.mm:740-770`). Unlike the
     temporal scaler, `MTLFXTemporalDenoisedScaler` has no `inputContentWidth/Height`.
   - FrameGen sizes its interpolators from texture widths.
   - With the engine's DRS on, both would read the stale area outside the content rectangle **(verify)**. Today that
     never happens only because DRS is off.
5. **Bug: the plugin writes bool config variables at the wrong byte.**
   - The live value of a bool `CConfigVar` is at **+0x29**. +0x2C is its default.
   - Evidence: the bool vtable's getter and setter (`0x100a721a8`, `0x100a72258`) and every engine reader (for example
     `ldrb w8, [x8, #0x99]` = `DRS/Enable` + 0x29).
   - `ConfigVars.cpp` reads and writes `object + 0x2C` for bools. So every bool experiment so far changed only the
     default: the CAS toggle, `MFX/OverrideSharpness`, `FSR2/EnableHalton`, `Developer/FeatureToggles/*`,
     `RayTracing/Debug/SkipStaticMeshes`, `RayTracing/EnableNRD`. "No effect" for those is not a finding. Int and float
     variables are right (+0x2C, with min/max/default at +0x30/+0x34/+0x38).
6. **The engine never uses a MetalFX reactive mask.** Its selectors are registered (`0x101c04ad8`), but no code calls
   them. Particles, sparks, holograms, rain and other alpha-blended effects get no help against ghosting. That is
   worst at low render scales.
7. **The 50% floor is a menu limit, not an engine or MetalFX limit.**
   - `options.json` limits `DRS_MinResolution` to 50-100.
   - MetalFX on this M4 Max accepts content scales **1.0-3.0** (`supportedInputContentMin/MaxScaleForDevice`, queried).
   - So the engine's DRS could run from 33% to 100% without reallocation.
8. **Mip bias, jitter and sharpening** (§6):
   - The engine's texture bias already follows the scale every frame, as `log2(render/output) − 1`. That includes
     `ultra_scale` rewrites. The plugin's `texture_lod_bias` stacks on top (too negative: texture shimmer).
   - The jitter phase count, `8·(out/render)²`, is recomputed every frame, so each DRS width change jumps the Halton
     index.
   - On the MetalFX path, CAS sharpening is the constant `MetalFX_Sharpness`.
   - Texture streaming does not depend on render resolution at all.
9. **Current settings.**
   - Upscaler: MetalFX Performance (the setting is stored as `ResolutionScaling = "FSR2"`, which the menu shows as
     MetalFX; values and display names are shifted by one).
   - DRS settings: off, target 120 fps, min 50%, max 100%.
   - If DRS were turned on with path tracing, a 120 fps target pins it at the 50% floor. Max 100% would also make every
     render-size target native size (memory and clears; §5.6).

**Top proposals, in order**

| # | Change | Effect | Size |
|---|---|---|---|
| P0 | Fix bool config variables (+0x29), going through the engine's setter (it clamps and notifies) | Bool knobs work at all; old bool results need retesting | small |
| P1 | Make the engine's DRS the backend of `dynamic_scale_fps` (MetalFX "Dynamic"), not the scale table | No 150-170 ms hitches, no history resets, any scale from 1.0x to 3.0x | medium |
| P2 | Steady the controller: hook `DRS::Update`, snap to a short ladder with hysteresis, fix the jitter phase count, freeze while the camera is still | Few, rare steps, hidden in motion; no jitter sequence jumps | medium |
| P3 | Content-rectangle awareness in Denoise and FrameGen (resample into a fixed canvas inside passes that already exist) | Apple denoiser and frame generation work with DRS; no extra passes | medium |
| P4 | `texture_lod_bias` 0 (stop double-counting); engine CAS strength by content scale; RCAS strength by scale | Less texture shimmer; lines crisp at every scale; no new pass | small |
| P5 | Reactive mask from a pre/post-transparency difference | Less ghosting and smearing of particles and holograms at Performance | medium |
| P6 | Remove copies (RCAS blit, FrameGen 2x blits, depth/motion snapshots folded into compute) | About 0.3-0.8 ms back per frame at 3456x2160 | small each |

## 2. Call graph

```
Settings
  r6/config/settings/platform/mac/options.json
    /graphics/presets:
      ResolutionScaling ["Off","FSR2","FSR3","MetalFX"]   menu shows: Off, MetalFX, FSR2, FSR3 (shifted)
      MetalFX ["Auto","Quality","Balanced","Performance","Ultra Performance","Dynamic"]
      DynamicResolutionScaling (bool, hidden)
      DRS_TargetFPS 10..240, DRS_MinResolution 50..100, DRS_MaxResolution 50..100
    validators 0x10169ebb4 / 0x10169ec5c (min <= max); listener registration 0x1010e5708 (renderer +0x7dc8/+0x7dd0)
        |
        v
Renderer settings object  (pointer at 0x109003068, set by 0x1016c2a3c)
    vptr+0x3a8  GetDynamicResolution(out {minH, maxH, refOutputH, targetFps, enabled})     (verify: exact fields)
    vptr+0x3a0  GetFixedUpscaleRatio(out ratioX, ratioY)   -> 0x100e5b1c4 GetScale: 1 / ScaleTable[q-1]
    vptr+0x300  GetGpuFrameTimes(out a, b, c)             (ms; DRS uses a*k + b + c; k = 1.0 on Mac)
    +0x144      float, relaxes the DRS target              (verify: likely the present interval in ms)
    +0x7680     upscaler state {+0x00 quality, +0x19 enabled, +0x1a dynamic (DRS), +0x1b recreate request}
        |
        v
Per-frame view setup  0x1010cd56c   (camera cut detection: FOV change > 0.25, camera jump > 100 units)
    |-- DRS::Update(state = ctx+0x2c, outRect lo, outRect hi, ctx)     0x1010cd188
    |       reads DRS/* config vars (§3.3)
    |       writes state.w/h (ctx+0x2c/+0x30), state.min/max
    |-- SetJitter(view, jx, jy, state.w, state.h, flags) x4 views     0x10168d400 -> 0x10168e134 (projection rebuild)
        |
        v
Render graph at state.w x state.h (fixed modes: textures exactly that size;
                                   DRS: textures at maxW x maxH, content rectangle at the top left)
        |
        v
MetalFX upscale node  0x100e5b2d0
    content = (ctx+0x2c, ctx+0x30)             -> s3, s4
    minScale = outW / maxW, maxScale = outW / minW   -> s5, s6
    jitter = (ctx'+0x3e0, -ctx'+0x3e4)          -> s1, s2
    reset = (ctx+0x1d44 >> 1) & 1 (camera cut)  -> w7
    dynamic = upscaler+0x1a, recreate = upscaler+0x1b | node+0x30   -> stack bytes
        |
        v
GpuApi MetalFX temporal encode  0x101c34c18
    (re)create when: no scaler | texture size != inputWidth/Height | output size changed | any format changed |
                     dynamic flag changed | (dynamic && min/max scale changed) | recreate requested
      descriptor: formats, inputWidth/Height = color texture size, output size, autoExposure NO,
                  dynamic: inputContentMinScale/MaxScale + inputContentPropertiesEnabled = YES
    every frame: setInputContentWidth/Height(content), motionVectorScale = content size, jitter, reset,
                 depthReversed YES, preExposure 1.0, exposureTexture nil, no reactive mask
        |
        v
[MTLFXTemporalScaler encodeToCommandBuffer:]  -- plugin hook H_fxTemporalEncode (MetalTrace.mm:2749)
    |-- Denoise::Active() && Denoise::EncodeScaler(...)   (Apple denoised scaler instead; game encode skipped)
    |-- else the game's own encode
    '-- FrameGen::AfterScaler (depth and motion snapshots, HUD, interpolation, pacing)

Plugin dynamic scale (today)
  MetalTrace OnPresent -> DynamicScale::OnFrame -> ConfigVars::SetUltraScale -> Upscaler/ScaleTable[3] (0x106b40e60)
      -> 0x100e5b1c4 GetScale (MFX/OverrideEnable + MFX/Quality=4) -> fixed path of DRS::Update -> new texture sizes
      -> all render-size resources reallocated + MetalFX recreated (+ history reset) -> 147-172 ms frame
```

## 3. Internals

### 3.1 DRS state (inside the per-view frame context, at ctx + 0x2c)

| Offset | Type | Meaning |
|---|---|---|
| +0x00 | u32 | render width (aspect x height) |
| +0x04 | u32 | render height (lines): the controlled value |
| +0x08 | u32 x2 | previous frame's width, height |
| +0x10 | u32 x2 | max width, min width |
| +0x18 | u32 x2 | max height, min height |
| +0x20 | u32 x2 | output width, height (viewport rectangle) |
| +0x28 | u32 | frames per decision (reloaded from `DRS/MinNumFrames`) |
| +0x2c | u32 | frames still to skip after a change (`DRS/FramesToSkip`) |
| +0x30 | f32 | summed frame time (ms) |
| +0x34 | u32 | frames summed |
| +0x38 | u8 | fixed override: a size forced by `0x1010cd548` (min = max = given) |

`ctx + 0x98` is the aspect ratio (width/height); `ctx + 0x17d8` (u16) holds upscaler-mode flags (DRS needs one of
mask 0x1ba0; the fixed-ratio path needs one of mask 0x1be0).

### 3.2 `DRS::Update` (0x1010cd188), as pseudocode

```c
void DRS_Update(DrsState* s, Rect out, FrameCtx* ctx) {
    if (s->override) return;
    s->outW = out.w; s->outH = out.h;
    float aspect = ctx->aspect;                          // +0x98
    s->prevW = s->w; s->prevH = s->h;
    DrsSettings g = {}; renderer->GetDynamicResolution(&g);    // vptr+0x3a8: {minH, maxH, refH, fps, enabled}
    if (cvar(DRS/Enable) && g.enabled && g.refH && g.maxH && g.minH >= 1 && g.minH <= g.maxH && g.fps
        && (ctx->upscalerFlags & 0x1ba0) && viewport valid && g.refH == s->outH) {
        s->maxH = g.maxH; s->minH = g.minH;
        s->maxW = aspect * g.maxH; s->minW = aspect * g.minH;
        if (g.maxH == g.minH && widths equal) { s->w = s->prevW = s->maxW; s->h = s->prevH = g.maxH; return; }
        float a, b, c; renderer->GetGpuFrameTimes(&a, &b, &c);
        float t = a * k + b + c;                          // k = 1.0 on Mac (platform id 11)
        float relaxed = renderer->f144;
        if (s->skip) s->skip--; else { s->sum += t; s->count++; }
        if (cvar(DRS/Freeze)) return;
        if (s->window == 0 || s->prevH == 0 || t == 0) {  // first frame: start at the max
            s->h = s->maxH; reset_window(s); goto clamp;
        }
        if (skipped_this_frame || s->count < s->window) goto clamp;
        float target = 1000.f / g.fps;
        target = max(target, min(0.9f * relaxed, target + 2.f));   // relaxed by at most 2 ms
        float d = target - s->sum / s->count;              // ms under (+) or over (-) budget
        float lines = d < 0 ? -min(DownRate * -d, MaxDownStep * s->count)
                    : d > 0 ?  min(UpRate * d,   MaxUpStep  * s->count) : 0;
        int step = clamp(StepSize, 1, 100);
        int h = clamp(s->prevH + step * round(lines / step), s->minH, s->maxH);
        if (h != s->h) { s->h = h; s->skip = FramesToSkip; }
        reset_window(s);                                  // window = MinNumFrames, sum = count = 0
    clamp:
        s->h = clamp(s->h, s->minH, s->maxH); s->w = aspect * s->h;
        return;
    }
    if (ctx->upscalerFlags & 0x1be0) {                    // fixed upscaler quality
        float rx, ry; renderer->GetFixedUpscaleRatio(&rx, &ry);   // 1 / ScaleTable[q-1]
        s->w = s->min = s->max = max(1, (int)(outW * rx + 0.5f)); /* same for h */
    } else { s->w = outW; s->h = outH; }                  // native
    s->sum = 0; s->count = 0;
}
```

### 3.3 The `DRS/*` config variables (registration in `0x1010d2d98`, all read only by `0x1010cd188`)

| Variable | Object | Type | Default | Engine range | Role |
|---|---|---|---|---|---|
| `DRS/Enable` | 0x108fea070 | bool (+0x29) | 1 | | master switch |
| `DRS/Freeze` | 0x108fea0a0 | bool (+0x29) | 0 | | hold the current size (still accumulates timing) |
| `DRS/ForceMaxRes` | 0x108fea0d0 | bool | 0 | | **no reader** in this build |
| `DRS/ForceMinRes` | 0x108fea100 | bool | 0 | | **no reader** in this build |
| `DRS/DownRate` | 0x108fea130 | float | 24.0 | 0.01-100 | lines per ms over budget |
| `DRS/UpRate` | 0x108fea170 | float | 8.0 | 0.01-100 | lines per ms under budget |
| `DRS/MaxDownStep` | 0x108fea1b0 | float | 100 | 1-1000 | cap, lines per summed frame |
| `DRS/MaxUpStep` | 0x108fea1f0 | float | 50 | 1-1000 | cap, lines per summed frame |
| `DRS/StepSize` | 0x108fea230 | int | 8 | 1-100 | quantum in lines (also clamped 1-100 in code) |
| `DRS/MinNumFrames` | 0x108fea270 | int | 4 | 1-32 | frames per decision |
| `DRS/FramesToSkip` | 0x108fea2b0 | int | 2 | 1-8 | frames ignored after a change |

All are verified `CConfigVar`s (bool/int/float vtables `0x106e9e818` / `0x106e91c00` / `0x106ea88e0`). Layout:
- name +0x8, group +0x10, flags +0x28;
- bool: value +0x29, min +0x2a, max +0x2b, default +0x2c, has-range +0x2d;
- int/float: value +0x2c, min +0x30, max +0x34, default +0x38, has-range +0x3c.

The typed setter (vptr slot 5; bool `0x100a72258`, int `0x100963834`, float `0x100b28494`) clamps to the range and calls
the change notifier `0x101e35528`. A raw store skips both.

What the defaults mean at 3456x2160 output (2160 lines; Performance = 1080):
- With 33.3 ms frames and a 2 ms overshoot, the next decision drops 48 lines (2.2%).
- A decision comes at most every 6 frames (4 measured + 2 skipped). In a scene that sits near the target, the content
  size changes several times a second.
- Each change moves the jitter grid (`SetJitter` gets the new size), the motion vector scale and the content rectangle
  together. MetalFX then resamples its history to the new grid. That is the "breathing" and shimmer of DRS.

### 3.4 Fixed scales: `Upscaler/ScaleTable` (0x106b40e60)

- The table holds `[1.5, 1.7, 2.0, 3.0]`, for quality 1-4 (Quality, Balanced, Performance, Ultra Performance).
- `0x100e5aec8` returns `table[q-1]`, or 0 for q outside 1-4.
- `0x100e5b1c4` returns the ratio `1/table[q-1]` (1.0 for q = 0). It reads the quality from `MFX/Quality` when
  `MFX/OverrideEnable > 0`, else from the upscaler state.
- Six code sites read the table (0x100e4d834, 0x100e4db44, 0x100e51528, 0x100e541dc, 0x100e5aed8, 0x100e5b214): one
  pair for each of FSR2, FSR3 and MetalFX.
- `ConfigVars::SetUltraScale` rewrites entry 3 through a copy-on-write page. Every write is a fixed-size change: a full
  reallocation.

### 3.5 MetalFX wrapper (`0x101c34c18`)

- The game uses metal-cpp style selectors: `sel_registerName` in the static initializer `0x101c04ad8`, stored in globals
  0x1090088f8-0x109008a50. That is why the selectors are in `__cstring`, not `__objc_methname`.
- Recreate checks: `inputWidth/inputHeight` (sel 0x890/0x888) against the color texture's size; output size
  (0x920/0x900); color, depth, motion and output formats (0x828/0x840/0x8d0/0x910); the content min/max scale getters
  (0x878/0x870) against the requested range; whether content properties are on; and a recreate request.
- The descriptor sets `autoExposureEnabled = NO`. Content min/max scale and `inputContentPropertiesEnabled` are set
  only in the dynamic mode.
- Per frame it sets: textures, `inputContentWidth/Height`, `motionVectorScaleX/Y` = content size (motion in UV units),
  `jitterOffsetX/Y` (Y negated), `reset` (camera cut bit), `depthReversed = YES`, `preExposure = 1.0`,
  `exposureTexture = nil`.
- `setReactiveMaskTexture:` and `setReactiveMaskTextureEnabled:` (globals 0x109008a30/0x109008a38) have no readers.
- Plugin log of the fixed mode (Performance or ultra_scale): `autoExposure=0 inputContentProperties=0`. One scaler per
  size seen in play: 1152x720, 1172x732, 1213x758, 1257x785, 1355x847, 1471x919, 1536x960, 1607x1005, 1686x1054, each
  a new object.

### 3.6 MetalFX limits on this Mac (queried 2026-10-10)

- `supportedInputContentMinScaleForDevice` = 1.0 and `supportedInputContentMaxScaleForDevice` = 3.0.
- A temporal scaler with content range 2-3 creates; 1-4 returns nil.
- `MTLFXTemporalDenoisedScalerDescriptor supportsDevice` = YES. The denoised scaler has no content-rectangle properties.
  It has a reactive mask, a specular hit distance, a denoise-strength mask and a transparency overlay (macOS 26).

### 3.7 Plugin side (file:line)

- **Scaler hooks:** `H_fxTemporalNew` (MetalTrace.mm:2835) logs the descriptor and hooks `encodeToCommandBuffer:`.
  `H_fxTemporalEncode` (:2749) runs `Denoise::EncodeScaler` or the game's encode, then `FrameGen::AfterScaler` (:2798).
- **Denoise:**
  - Skips when the G-buffer size differs from `inputWidth/Height` (Denoise.mm:744).
  - Recreates on input/output size or color/motion format changes (:748; depth format not checked), with
    `requiresSynchronousInitialization = YES` (:764).
  - Never reads `inputContentWidth/Height`.
  - No reactive mask, hit distance, strength mask or transparency overlay.
- **RCAS** (Denoise.mm:177-212, 694-716): only on the denoised path, in a reversible tone-mapped space. It costs a full
  output blit into `g_sharpSrc` and an output-size dispatch. The game's MetalFX path gets no plugin sharpening.
- **`texture_lod_bias`:** added in `H_newSampler` (MetalTrace.mm:1976) when a sampler is created, once per game start.
  It cannot follow a dynamic scale.
- **FrameGen:**
  - Interpolators are sized from texture widths (FrameGen.mm:646, 1148).
  - Depth and motion are blitted whole at render size (:451-462).
  - 2x path: two output-size blits (`g_cur`, the real overlay drawable).
  - 4x path: `s.real`, depth, motion, UI copies per frame (:843-880).

## 4. Why a dynamic render size looks worse than a fixed one

1. **Frequent small steps.** Every 6 frames is possible (§3.3). Each step moves the jitter lattice and makes MetalFX
   resample its history, so static scenes shimmer and edges "breathe". At 120 fps targets with path tracing the
   controller pins at the floor, so DRS only adds the dynamic-mode scaler at its minimum.
2. **Plugin steps reset history.** Every scale-table write recreates the scaler. For several frames there is no
   temporal accumulation: aliasing and noise, the most visible kind (with path tracing, the denoiser's history too).
   Then comes the 147-172 ms hitch.
3. **The jitter sequence jumps on each step.** The phase count is 8·(out/render)², recomputed every frame. A width
   change moves `counter % phases` to an unrelated Halton index (§6.4).
4. **Texture bias overshoots, and every bias change rebuilds all samplers.**
   - The engine's bias already tracks the scale (log2 ratio − 1, §6.1).
   - The plugin's `texture_lod_bias` stacks on top as a constant: too negative, so textures alias (noise).
   - Under DRS each 1/16 bias change rebuilds every sampler.
5. **Sharpening does not follow the scale.** On the MetalFX path the engine's CAS uses the constant `MetalFX_Sharpness`.
   The plugin's RCAS strength is also constant and runs only on the denoised path. Lower content scales need more
   sharpening, higher ones less (otherwise grain).
6. **Alpha-blended effects ghost.** No reactive mask, so MetalFX trusts history for particles and holograms; at 50% and
   below they smear.
7. **Plugin passes and the content rectangle.** With the engine's DRS, the denoised scaler and frame generation would
   use the whole max-size texture **(verify)**.

## 5. Proposals

Each proposal lists mechanism, hook points, expected effect, risks, and the measurement that settles it (one question
per run, as in the other scenarios).

### P0. Bool config variables at +0x29

- `ConfigVars::Apply`: for `Type::Bool`, read and write `object + 0x29`, not +0x2C.
- Better: call the typed setter (vptr slot 5) with the engine's type id, so ranges clamp and the change notifier runs.
  For the per-frame `DRS/Freeze` toggle (P2) a raw byte store at +0x29 is enough and race-free (single byte, the reader
  loads it once per frame).
- **Retest:** CAS toggle, `MFX/OverrideSharpness`, `FSR2/EnableHalton`, the FeatureToggles, `RayTracing/EnableNRD`,
  `Editor/MipBias/EnableCustomMipBias`.
- **Test:** cvarbatch `DRS/Freeze=1` with DRS on; the content size in the scaler log must stop changing.

### P1. The engine's DRS as the backend of `dynamic_scale_fps`

**Why:** it is the only path with no reallocation and no history reset (§3.5), and MetalFX allows content scales from
1.0 to 3.0 here (§3.6).

**How:**
1. Select MetalFX "Dynamic":
   - the player's setting; or
   - the plugin sets the upscaler state (`renderer+0x7680`: quality, `+0x1a` dynamic) before the first frame
     **(verify the quality index of "Dynamic")**.
2. Set the range:
   - `DRS_MinResolution` / `DRS_MaxResolution` through UserSettings (back up first; values 50-100 only, per the
     valid-values rule);
   - or, after confirming what vptr+0x3a8 returns, through a post-hook on `DRS::Update` (P2) that rewrites `s->minH` /
     `s->maxH`.
3. Go below 50% (3x = 33%):
   - edit `options.json` `min_value` (game file, backup) **(verify that vptr+0x3a8 does not clamp at 50)**;
   - or write `s->minH` in the hook.
4. Retire the scale-table path for dynamic use. Keep `ultra_scale` only as a fixed setting.

**Effect:** the 147-172 ms hitches and their history resets go away; scale moves continuously.

**Risks:**
- At max 100% every render-size target is native size: more memory, and clears sized by allocation (§5.6).
- Plugin passes need P3 first.

**Test:** the `dynscale` scenario with the engine path. Count frames over 50 ms after a step (expect 0) and steps per
minute.

### P2. Fewer, hidden steps (controller shaping)

**A. Config variables only** (after P0):

| Variable | Default | Proposed |
|---|---|---|
| `MinNumFrames` | 4 | 16-32 (averages GPU time noise, ±1.5 ms per frame) |
| `FramesToSkip` | 2 | 4 |
| `StepSize` | 8 | 54 lines (2.5% of 2160) |
| `UpRate` | 8 | 2 (slow way up) |
| `DownRate` | 24 | 24 (fast way down protects frame time) |
| `MaxUpStep` | 50 | 16 |

Floats and ints, valid within their engine ranges.

**B. Post-hook on `DRS::Update`** (0x1010cd188; RED4ext hook on a verified address; x0 is the state, layout §3.1):
- **Snap to a ladder.** Hold a short list of levels (for example 1080, 1188, 1296, 1440 lines at 3456x2160: 2.0x,
  1.82x, 1.67x, 1.5x). The ladder could be aligned to the scales where the jitter sequence was designed (see §6).
- **Hysteresis.** Go up only when the predicted time at the next level (pixel-scaled, as in DynamicScale.cpp) stays
  15% under the target for 2 s; go down at once on 8% over.
- **Safe access:** write only `s->w`/`s->h` (+0x00/+0x04), clamped into `[s->minH, s->maxH]`. Never write outside the
  struct; skip when `s->override` (+0x38) is set.

**C. Fixed jitter phase count.**
- Hook MetalFX's phase-count source (`0x100e5aeb0`, or the length computation in `0x1010c9834`) to return one constant
  while DRS is on. Use the count for the ladder's lowest scale (32 at 2x), or 72 for a range reaching 3x.
- The Halton index then never jumps on a size change. A longer sequence than a level needs is harmless (still low
  discrepancy); a shorter one is not.

**D. Motion gate.** While the camera is still (Warp::Capture already reads yaw and pitch from NRD's constants; add
translation from gViewToWorld's column 3), set `DRS/Freeze = 1`.
- Changes then happen only during turns and movement, when MetalFX's history is already short and motion hides the
  change.
- A downward step needed for frame time is still allowed after 0.5 s.
- Camera cuts (the reset bit, `ctx+0x1d44` bit 1) are free moments to change level: no history to lose.

**Test:** fixed spot, 60 s. Steps per minute; flicker (frame-to-frame PSNR of a still scene: compare fixed Performance,
default DRS, shaped DRS).

### P3. Content-rectangle-aware plugin passes

**Denoise, fail-closed first:**
- If `s.inputContentWidth != s.inputWidth || s.inputContentHeight != s.inputHeight`, return false: the game's own
  temporal scaler handles the content rectangle. One line, no wrong image.

**Denoise, full version (fixed canvas):**
- In the guides kernel that already runs each frame at G-buffer size (`mfxd_guides`), resample the content rectangle of
  color, depth and motion into fixed-size canvases.
- Scale jitter by `canvas/content` and motion vector scale to the canvas size.
- The denoised scaler keeps one size and its history across DRS steps.
- Cost: three render-size reads and writes inside an existing dispatch, no new pass.
- Quality: bilinear resampling blurs the sub-pixel jitter slightly; compare against fixed Performance with the motion
  and skin scenarios.

**FrameGen:**
- Replace the depth and motion blits in `AfterScaler` with one compute pass that copies the content rectangle into the
  fixed-size snapshots (resampling as above). Removes two blits, adds one dispatch.
- Pass the content size to `fg_down` and the HUD pass for UV scaling.

### P4. Texture detail and sharpness that follow the scale

**Mip bias** (§6.1: the engine already applies `log2(render/output) − 1` each frame):
- Set `texture_lod_bias = 0` by default and fix the template's advice (it double-counts).
- To trade a little texture sharpness for less texture shimmer at Performance, use a *positive* offset: −0.5 instead
  of −1 net. After P0, drive `Editor/MipBias/EnableCustomMipBias` (+0x29) and `ForceCustomMipBias` (+0x2C) each frame
  as `log2(content/output) − 0.5`. Rounding to 1/16 stays (each change rebuilds samplers).
- Under DRS, rate-limit bias changes: hold the bias while the content scale stays within ±1/16 of a log2 step. That
  avoids sampler rebuilds every few steps. With the ladder (P2-B) this comes for free.

**Sharpening that follows the scale, with no new pass:**
- Write the engine CAS strength `mfx+4` (`renderer+0x7680` object, float; getter `0x100e5b0f0`) each frame:
  `s = clamp(base · (output/content) / 2, 0, 0.8)`. With base 0.4: 2x 0.40, 2.5x 0.50, 3x 0.60, 1.5x 0.30.
- That uses the engine's own CAS pass (already running after MetalFX). It needs the CAS toggle on (+0x29) and adds no
  copies.
- Same formula for the plugin's RCAS on the denoised path. Keep the lobe limit (−0.1875·amount) so lines stay sharp
  without halos.

**Line preservation:** RCAS on luma only, with chroma from the unsharpened output. That avoids colour fringing on
neon edges.

**Test:** Laplacian detail and flicker at 2x / 2.5x / 3x, as in the 3x image-quality section of STATUS.md, with
`texture_lod_bias` 0 against the current −0.17.

### P5. Reactive mask

The engine does not provide one (§3.5). Two cheap sources:

1. **Pre/post transparency difference.**
   - Snapshot the color target before the first transparent/forward pass (one render-size copy, ~0.05 ms at
     1728x1080); after the scene, mask = saturate(k · |post − pre| / (post + ε)).
   - Feed it to the temporal scaler (descriptor `reactiveMaskTextureEnabled`, macOS 14.4+) or the denoised scaler
     (macOS 26).
   - Requires recreating the scaler once with the flag; done in the plugin's own descriptor hook.
2. **Particle/hologram passes.** Identify their pipelines by name in the tracer (MetalTrace already names passes) and
   write alpha into an R8 mask in a fragment-stage hook.

**Test:** fgeval-style captures of sparks and holograms (ghost energy behind moving particles).

### P6. Fewer copies (per frame at 3456x2160; RGBA16F output ≈ 57 MiB, a full-screen copy ≈ 0.24 ms measured)

| Copy | Where | Change |
|---|---|---|
| RCAS source blit | Denoise.mm:705 | Denoised scaler writes into a plugin texture; RCAS writes the game's output: −1 output copy |
| 2x `g_cur` + real overlay | FrameGen.mm:1050, 1213 | HUD pass reads the game's drawable and writes the overlay drawable; the real frame goes through the same compute: −1 to −2 output copies |
| Depth/motion snapshots | FrameGen.mm:451-462 | One compute that also does the content-rectangle resample (P3) |
| 4x `s.real` | FrameGen.mm:843 | Present the game's drawable texture content through the warp/HUD compute (it already writes the drawable) |
| Engine clears | 68 fills, 472 MiB at 3x | Only where the buffer is fully rewritten (unchanged rule); measure first |

### P7. Memory, streaming, hot load and parallelism

- **Max resolution sets memory.** With DRS, render-size targets are allocated at max. At max 100% that is native
  3456x2160 for every G-buffer and path-tracing target, about 4x the Performance size. Keep max at 67-77% (Quality to
  above-Quality): sharper than Performance when there is headroom, no native-size allocations. If the per-frame buffer
  fills are sized by allocation, they would scale the same way **(verify with the fill hook, `fillBuffer` is already
  hooked)**.
- **Pre-warm, so a level change never compiles.**
  - Fixed-scale path (`ultra_scale`): create the denoised scaler for each ladder size on a background queue at load
    (`requiresSynchronousInitialization = NO`) and cache them by size; switch by pointer.
  - Engine DRS path: no recreation exists.
- **Deferred work off the render thread.** Scale decisions (P2) are made on the present thread from GPU timestamps
  (`MTLCommandBuffer` `GPUStartTime`/`GPUEndTime`, already read by the tracer). They are published with one atomic
  store; the DRS hook reads them. No locks on the render thread.
- **GPU time attribution.** The engine's DRS timing (vptr+0x300) likely includes plugin work on its queue (Apple
  denoiser, 2x frame generation). With frame generation on, the controller sees ~4-7 ms more per frame and drops
  resolution further. Either keep generation on the pacer's queue (4x already does), or subtract the plugin's measured
  GPU time from the target (adjust `DRS_TargetFPS` once) **(verify which times vptr+0x300 reports)**.
- **Texture streaming:** nothing to tune (§6.2). There are no streaming budget variables, and at Texture Quality High
  every texture loads its top mip regardless of render scale. "Textures at near native resolution" is purely a
  sampler-bias question (P4). Keep High; Medium/Low drop whole mips at load.

### P8. Safe memory access rules for all of the above

- Addresses only from the verified address DB; for objects, check name/group/vtable as ConfigVars.cpp does. For
  `DRS::Update`, add a prologue-pattern entry with `snap_prologue_offsets.py` before hooking.
- Write only aligned 32-bit values or single bytes the engine reads once per frame. Never write `__TEXT` for dynamic
  behaviour (the scale-table COW write stays a fixed-scale tool only).
- Prefer the engine's setter for config variables (range clamp plus notifier). Use raw stores only for per-frame
  toggles whose reader is known (`DRS/Freeze`).

## 6. Mip bias, sharpening, jitter and streaming in the engine

Frame flags (built by `0x1010fca44`, stored at `frame+0x17d8`): 0x80 FSR2, 0x100 DLSS, 0x1000 MetalFX. Upscaler
objects: `renderer+0x7670` FSR2, `+0x7678` DLSS, `+0x7680` MetalFX. Render size is at `frame+0x2c/+0x30`, output size at
`+0x4c/+0x50`.

### 6.1 Mip bias: already follows the scale, every frame

**Computation** (`0x10110e85c`, from the per-frame path via `0x10110e544`):
- `EnableCustomMipBias` set: raw = `ForceCustomMipBias`.
- DRS on: raw = `log2(renderH / outputH) - 1`, from the live DRS height each frame.
- Fixed upscaler: raw = `log2(1 / ScaleTable[q-1]) - 1`. Because it reads the table, **an `ultra_scale` rewrite is
  already followed by the engine**.
- No upscaler: raw = 0.

**Final value:** `bias = clamp(round(raw * 16) / 16, -3, 0) + settings(0x108ffce68)+0x34` (writer of that offset not
found). Performance gives −2.0, Quality −1.5625, 3x −2.5625.

**Delivery:**
- `0x101bf36d4` stores {bias, anisotropy} in the GPU device (`*(0x109008b48)+0x10/+0x14`). On any change it calls
  `0x101c43770`, which **rebuilds every sampler**.
- The bias reaches shaders through the Metal Shader Converter sampler heap: `0x101c0319c` writes
  `{gpuResourceID, 0, lodBias}` per sampler, adding the global bias for samplers with flag bit 1. It is not in a
  constant buffer and not in `MTLSamplerDescriptor.lodBias` (all 0, as measured).
- So the plugin's `texture_lod_bias` (added to `MTLSamplerDescriptor.lodBias` at creation) **stacks** on the engine's.

**Consequences:**
- The config template's advice `texture_lod_bias = log2(2 / ultra_scale)` double-counts. The engine already applies
  log2 of the ratio, plus −1. Extra negative bias trades texture detail for texture aliasing: noise that the
  upscaler then has to clean up.
- Under DRS the bias moves in 1/16 steps. Each change rebuilds every sampler; at 2160 output that is about every 6th
  8-line step **(measure the cost of `0x101c43770`)**.
- `XESS/InternalMipBiasDelta` has no readers.

### 6.2 Texture streaming and quality

- No texture-streaming, pool, budget, residency or anisotropy config variables exist (all 1519 registrations scanned).
- `TextureQuality` is a static top-mip drop: `0x1016b5764` / `0x1016b562c` give drop 2/1/0 for Low/Medium/High in
  `0x108ffcf70`, applied at texture load (`0x10106e7dc`, `0x10106f4a8`).
- **No streaming code reads the render resolution.** At High, textures are full resolution regardless of DRS; only the
  sampler bias decides which mip a pixel reads.
- Other budgets: `RayTracing/BlasCache/Budget` 900 MiB; `World/Streaming/PersistencyCache/PoolBudgetKB` 4096 (world
  state); `Rendering/FakeGPUVRAM` and friends (no readers).

### 6.3 Sharpening

- `CRenderNode_ApplyContrastAdaptiveSharpening` (vtable `0x106ef9348`, execute `0x100fc6da0`) runs after the upscaler.
  It is gated by `Developer/FeatureToggles/ConstrastAdaptiveSharpening` (bool, read at `0x1010fd96c`; +0x29, so the
  plugin's earlier toggle never reached it).
- Strength:
  - DLSS: the DLSS sharpness.
  - **MetalFX: `mfx+4` (getter `0x100e5b0f0`), set from the `MetalFX_Sharpness` user setting (0.5). A constant, not
    scaled by DRS.**
  - Otherwise: the environment's `SharpeningAreaSettings`, which scale with renderH/outputH each frame. Engine
    precedent for scale-aware sharpening, but not on the MetalFX path.
- `MFX/Sharpness`, `MFX/OverrideSharpness` and `MFX/SharpnessOverride` have no readers. That explains the "no effect"
  in STATUS.md independently of the bool bug.

### 6.4 Jitter

`0x1010c9834`, called at `0x1010cdbdc`, **before** DRS::Update in the same frame setup (so it likely uses the previous
frame's width: a one-frame lag).
- `phases = trunc(8 * (outW / renderW)^2)`: 32 at 2x, 18 at 1.5x, 72 at 3x.
- Sample = Halton(2,3) at index `(counter % phases) + 1`, minus 0.5. The counter is a global frame counter (`+0x1660`).
- MetalFX gets its phase count through `0x100e5aeb0`, DLSS through `0x100e51968`.
- FSR2 uses the formula only with `FSR2/EnableHalton`; else an R2 sequence of unbounded length.
- **Under DRS the phase count changes with every width change.** `counter % phases` then jumps to an unrelated index,
  so the sample pattern loses its low-discrepancy coverage for a cycle. That is shimmer on top of the history resample.

## 7. Runtime checks still open

1. vptr+0x3a8 output: does it clamp `minH` at 50%? What is `refH`? Hook-free check: read the DRS state at ctx+0x2c from
   the existing camera watch, or log `s->minH/maxH` from a `DRS::Update` post-hook.
2. The quality index of MetalFX "Dynamic", and whether `renderer+0x7680 +0x1a` follows it.
3. With DRS on: does `Denoise::EncodeScaler` produce a wrong image (expected) and does frame generation misalign
   (expected)? One rtbench run each, saved frames.
4. Which GPU times vptr+0x300 returns (game queue only, or all queues).
5. Buffer fills under DRS max 100%: sized by allocation or by content.

## Appendix: addresses (2.3.1, macOS)

| Address | What |
|---|---|
| 0x1010cd188 | `DRS::Update(state, outLo, outHi, ctx)` |
| 0x1010cd548 | DRS fixed override setter (sets +0x38, sizes) |
| 0x1010cd56c | Per-view frame setup (calls DRS::Update at 0x1010cdfc0, SetJitter x4) |
| 0x10168d400 | `SetJitter(view, jx, jy, w, h, flags)` then projection rebuild 0x10168e134 |
| 0x1010d2d98 | Static init: `DRS/*`, `FSR2/EnableHalton`, `FSR2/SampleNumber` config variables |
| 0x108fea070-0x108fea2f0 | `DRS/*` config variable objects |
| 0x106b44980-0x106b449ef | `DRS/*` defaults (value, min, max, default blocks) |
| 0x106b40e60 | `Upscaler/ScaleTable` [1.5, 1.7, 2.0, 3.0] |
| 0x100e5aec8 / 0x100e5b1c4 | ScaleFor(q) / GetScale (ratio, honours MFX/OverrideEnable) |
| 0x100e5b088 | MetalFX enabled (MFX/OverrideEnable or state +0x19) |
| 0x100e5b2d0 | MetalFX upscale render node (calls the encode at 0x100e5bb70) |
| 0x101c34c18 | GpuApi MetalFX temporal encode (create/recreate, per-frame properties) |
| 0x101c04ad8 | metal-cpp selector registration (MetalFX selectors at 0x1090088f8-0x109008a50) |
| 0x109003068 | Renderer settings object pointer (set by 0x1016c2a3c) |
| 0x1010e5708 | `/graphics/dynamicresolution` listener registration |
| 0x10169ebb4 / 0x10169ec5c | DRS min/max validators |
| 0x103d79808 | Benchmark summary ("DRS: %s") |
| 0x100a72258 / 0x100963834 / 0x100b28494 | Config variable setters (bool / int / float) |
| 0x10110e85c | Mip bias: `clamp(round(16·(log2(ratio) − 1))/16, −3, 0) + settings+0x34` |
| 0x101bf36d4 / 0x101c43770 / 0x101c0319c | Bias/anisotropy setter; rebuild all samplers; sampler heap entry writer |
| 0x1010c9834 | Jitter: phases = 8·(out/render)², Halton(2,3) at `counter % phases + 1` |
| 0x100e5aeb0 / 0x100e51968 | MetalFX / DLSS jitter phase source |
| 0x100fc6da0 | CAS render node execute (strength from `mfx+4` getter 0x100e5b0f0 on the MetalFX path) |
| 0x1016b5764 / 0x1016b562c | TextureQuality to mip-drop count (0x108ffcf70) |
