# Renderer findings (macOS Cyberpunk 2077 2.3.1)

Measured with the plugin's native Metal tracer (`src/plugin/MetalTrace.mm`) and RED4ext's `tools/rtbench`, on an
M4 Max (macOS 26.7) in a 1168x730 window. Raw runs live in `RED4ext/runs/<timestamp>-rtbench/` (frame traces,
frame timings, screenshots, `rtbench.md`).

## How the renderer is built

- **Shaders are converted HLSL.** Every game compute kernel is `cs_main_`, every vertex/fragment function
  `vs_main_`/`ps_main_`, with the binding layout of Apple's Metal Shader Converter: `top_level_global_ab` (root
  signature, buffer 2), `res_desc_heap_ab` (resource descriptor heap, buffer 0), `smp_desc_heap_ab` (samplers,
  buffer 1). Resources are bindless: kernels read and write textures through the descriptor heap, not through
  `setTexture:atIndex:`. Encoders declare them with `useResource:usage:` (traced as residency, read/write) and
  `useHeap:`.
- **Pipelines carry a stable numeric label** (for example `3496549227`), set by the engine. It is the best key for a
  pass across runs. Its derivation is unknown (not a common hash of the shader name).
- **Ray tracing pipelines keep their names:** ray generation kernels are named `rgs_shadow_main`,
  `rgs_shadow_transparent_main`, `rgs_diffuse_main`, `rgs_importance_main`, `rgs_reflection_opaque_main`,
  `rgs_reflection_transparent_main`, `rgs_reference_main` (path tracing),
  `rgs_restirgi_spatiotemporal_epilogue` (path tracing).
- **Shader libraries come from the game's caches** (`engine/shadermetal_final.cache`,
  `engine/staticshadermetal_final.cache`); `scripts/shader_index.py` maps each library the game creates to its cache
  entry. The static cache has a name table (REBLUR_*, RELAX_*, SIGMA_*, m_rtxdi*, m_rayTracedReference_*, ...), but its
  layout is only partly decoded: names from it are tentative (shown as `~name`), and some are wrong (path tracing names
  appear in raster frames).
- **The NRD CPU entry points are not the integration point.** The REBLUR/RELAX/SIGMA work runs as converted compute
  kernels dispatched by the engine.

## Frame cost (rtbench, 2026-10-07)

GPU time per frame at 779x487 render resolution (1168x730 output), steady windows only:

| Mode | GPU ms (median) |
| --- | ---: |
| Raster | 5.5-6.3 |
| RT Ultra | 11-15 |
| RT Psycho | 13-16 |
| Path tracing | 19-31 |

About half of the 180-frame windows were not steady: medians of 45-140 ms in every mode, and p99 of 150-400 ms almost
everywhere. Causes seen: areas still streaming after a teleport, and other apps in use on the same GPU during the runs.
Next: several windows per spot (report the best and the worst), runs on an otherwise idle Mac.

## Ray tracing workload (spot 0, RT Ultra)

- Acceleration structures per frame: 312 BLAS refits, 36 BLAS builds, 2 TLAS builds (`MTLPrimitive` /
  `MTLInstanceAccelerationStructureDescriptor`).
- 406 compute dispatches per frame (raster: ~210); 53 compute pipelines run only with ray tracing, 81 only with path
  tracing (rtbench report: "Compute pipelines in <mode> but not raster").
- Ray generation passes write 779x487 (render resolution) targets: RGBA16Float, RG16Float, R16Float, R32Uint, RG8Unorm.
- Path tracing is a wavefront tracer: `rgs_reference_wavefront_trace`, `rgs_reference_wavefront_shade`,
  `rgs_reference_wavefront_lightid_prefetch`, plus `rgs_reference_main` and the ReSTIR GI epilogue
  (`rgs_restirgi_spatiotemporal_epilogue`); 485 dispatches and 357 acceleration structure operations per frame.

## G-buffer and upscaler inputs (render resolution 779x487, output 1168x730)

- G-buffer pass: two BGR10A2Unorm targets, one RGBA8Unorm, one RGBA16Float, depth Depth32Float_Stencil8. Which target
  holds normals, base color, roughness and metalness is not mapped yet.
- MetalFX temporal scaler, when the game uses it: color RGBA16Float, depth Depth32Float_Stencil8 (reversed Z), motion
  RG16Float in UV units (motion vector scale = input size), jitter in pixels, no exposure texture, pre-exposure 1.
- The upscaler option is not what its label says: with the user's setting "FSR2" the game creates and calls the MetalFX
  temporal scaler (internal kernels `brnetv3_*`); with "MetalFX" set in UserSettings.json before launch it does not.
  To be resolved before benchmarking upscalers.

## Corrections to earlier notes

- The "denoiser candidate" pipelines of the retired tracer (2024x847 motion and depth, 1720x720 history, 3440x1440
  output) were MetalFX's own temporal upscaler kernels, not the game's denoiser.
- Pixel format numbers were mislabeled: 13 is R8Uint, 23 R16Uint, 30 RG8Unorm (not R8Unorm / RGB10A2), 62 RG16Snorm,
  94 BGR10A2Unorm.

## Open

- Decode the top-level argument buffer per dispatch (root signature to descriptor heap indices) to name each
  dispatch's exact textures; this is what maps NRD's inputs (normal/roughness, view Z, motion, hit distance) and
  outputs.
- Finish the static cache name table so passes get reliable names.
- Settings changed at runtime (UserSettings) read back as changed but do not switch the ray tracing renderer; rtbench
  therefore sets each mode before launch.
