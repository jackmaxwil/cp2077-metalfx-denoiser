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
- **Shader libraries come from the game's caches** (`engine/shadermetal_final.cache`: 19,019 material
  vertex/fragment libraries; `engine/staticshadermetal_final.cache`: 1,249 libraries, every compute and ray tracing
  shader). `scripts/shader_dump.py` dumps all of them (functions, types, surviving groupshared names);
  `scripts/shader_index.py` maps each library the game creates to its cache entry and names the static ones.
- **Static shader names are verified, not guessed.** The static cache's record table puts a compute shader's blob key
  110 bytes before its name, and a render shader's vertex/fragment keys 123/115 bytes before its render-target
  parameters and names. 785 names pass that rule plus a function-type check and are "verified". Checked against the
  game: every NRD kernel named this way dispatches 8x8 or 16x16 thread groups (16 of 16 in the traces), and raster
  frames contain no NRD or path tracing kernels. 174 names paired only by order are tentative (`~name`; about half of
  the NRD ones are wrong by the same check), 47 kernels have no name, 8 conflicts are dropped.
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

## What the frame spends its time on (passcost, 2026-10-08)

Skip test at the save's position with time frozen, MetalFX upscaling (779x487 to 1168x730), each part dropped in turn
and measured twice (`scripts/passcost_report.py`, runs `RED4ext/runs/20261008-1000*-passcost`):

| Part | RT Ultra (11.3 ms GPU) | Path tracing (17.1 ms GPU) |
| --- | ---: | ---: |
| Ray generation kernels (`rgs_*`) | 4.6 ms (41%) | 2.9 ms (17%) |
| NRD REBLUR/RELAX/SIGMA (verified names only: lower bound) | 1.0 ms (9%) | 0.7 ms (4%) |
| Acceleration structure refits (250-290 per frame) | 0.3-0.5 ms | 0.3 ms |
| MetalFX temporal scaler | about 0.1 ms | about 0.1 ms |

What this means for the goal:
- Replacing NRD saves at most about 1 ms here. The FPS lever is the amount of ray tracing (4.6 ms in RT Ultra).
- The denoiser swap pays the way DLSS Ray Reconstruction does: trace less (half resolution, fewer rays per pixel)
  and let a better denoiser hide the extra noise. The settings for that exist (`CONFIG_VARS.md`:
  `EnableHalfResolutionTracing`, path tracing `RayNumber`/`BounceNumber`).
- Refits are cheap; the earlier worry about 350 acceleration structure operations per frame does not matter.

## Ray tracing workload (spot 0, RT Ultra)

- Acceleration structures per frame: 312 BLAS refits, 36 BLAS builds, 2 TLAS builds (`MTLPrimitive` /
  `MTLInstanceAccelerationStructureDescriptor`).
- 406 compute dispatches per frame (raster: ~210); 53 compute pipelines run only with ray tracing, 81 only with path
  tracing (rtbench report: "Compute pipelines in <mode> but not raster").
- Ray generation passes write 779x487 (render resolution) targets: RGBA16Float, RG16Float, R16Float, R32Uint, RG8Unorm.
- Path tracing is a wavefront tracer: `rgs_reference_wavefront_trace`, `rgs_reference_wavefront_shade`,
  `rgs_reference_wavefront_lightid_prefetch`, plus `rgs_reference_main` and the ReSTIR GI epilogue
  (`rgs_restirgi_spatiotemporal_epilogue`); 485 dispatches and 357 acceleration structure operations per frame.
- With MetalFX selected and RT Ultra, the MetalFX scaler's motion input is RGBA16Float (RG16Float in the other runs).

## G-buffer and upscaler inputs (render resolution 779x487, output 1168x730)

- G-buffer (tracer "dump", RT Ultra, `RED4ext/runs/20261008-120636-dump`): render targets are single-slice 2D arrays.
  The first pass to use them only clears them (normal 0.5, 0.5, 1); six more passes add geometry. Final contents:

  | Target | Format | Contents |
  | --- | --- | --- |
  | rt0 | BGR10A2Unorm | base color RGB; alpha: a 2-bit flag on a few objects |
  | rt1 | BGR10A2Unorm | world-space normal, xyz * 0.5 + 0.5 (Z up: floors are 0.5, 0.5, 1) |
  | rt2 | RGBA8Unorm | R metalness (0 or 1 on 95% of pixels), G roughness (continuous: asphalt high, glass low), B constant (shading model ID, probably), A a flag |
  | rt3 (some passes) | RGBA16Float | emissive (black here except a few lights) |
  | depth | Depth32Float_Stencil8 | reversed Z |

  Not in the G-buffer: specular albedo (derive from base color and metalness), specular hit distance and the noisy
  lighting (compute outputs of the ray generation passes, bindless; next to map).
- MetalFX temporal scaler, when the game uses it: color RGBA16Float, depth Depth32Float_Stencil8 (reversed Z), motion
  RG16Float in UV units (motion vector scale = input size), jitter in pixels, no exposure texture, pre-exposure 1.
- The upscaler option's index does not follow its labels: a saved "FSR2" at index 1 runs the MetalFX temporal scaler
  (internal kernels `brnetv3_*`); "MetalFX" at index 3 runs FSR3 (`m_ffx_fsr3upscaler_*` passes). The rtbench runs of
  2026-10-07 therefore measured FSR3 upscaling; tools/rtbench now selects index 1.

## NRD's inputs (tracer "dump" with dispatch textures, RT Ultra, `RED4ext/runs/20261008-121213-dump`)

`RTBENCH_DUMP=<labels> RTBENCH_SCENARIO=dump tools/rtbench rt_ultra` writes the textures that chosen dispatches declare
with `useResource` (read `-r`, written `-w`/`-rw`). For NRD's passes these declarations are exact (5-11 textures each):

| Texture | Format | Contents | Seen in |
| --- | --- | --- | --- |
| noisy diffuse radiance | RGBA16Float 779x487 | RGB radiance, A normalized hit distance; **half width**: the left 390 columns hold a checkerboard (half resolution tracing) | `RELAX_Diffuse_PrePass` (2146613912) read |
| noisy specular radiance | RGBA16Float 779x487 | the same layout, written by `rgs_reflection_opaque_main` (389 columns) | reflection ray generation write |
| view Z | R32Float 779x487 | linear depth | `RELAX_Diffuse_PrePass` read |
| normal and roughness | BGR10A2Unorm 779x487 | NRD's packed normal/roughness (not the G-buffer encoding) | every RELAX pass |
| denoised diffuse / specular | RGBA16Float 779x487 | outputs of `RELAX_Diffuse_AtrousSmem` (610715217) and the last `RELAX_Specular_Atrous` (3863891985) | |

The denoised outputs are not declared by any later dispatch: the passes that consume them reach them through
`useHeap` or a render pass. Finding that consumer is the next step for an NRD pass-through (copy reconstructed noisy
radiance into the denoised outputs and skip RELAX).

## Path tracing prototype: NRD pass-through and the denoised scaler (`Denoise.mm`, 2026-10-08)

Path tracing's RELAX runs in one serial compute encoder: two instances, each starting with HitDistReconstruction
(label 2684890295, first instance only) or PrePass (1624964913), which read the two noisy RGBA16Float radiance textures
(full resolution, demodulated: no albedo), and ending with four a-trous iterations (1807644384), the last of which
writes the instance's outputs. Each NRD texture is used through two objects 0x280 apart (read and write views). The
order-only shader names inside this encoder are wrong (the a-trous iterations are indexed as
`m_rayTracedHitShaderGI`).

The plugin's "denoise" mode (`METALFX_DENOISE=pass|fx`, or the tracer request `denoise off|pass|fx`) drops every
dispatch of both instances and copies the inputs to the outputs at the end of the encoder ("pass"); "fx" also replaces
the game's MetalFX temporal scaler call with `MTLFXTemporalDenoisedScaler`, fed guide textures computed from the
G-buffer (diffuse and specular albedo from base color and metalness, normals, roughness) and identity camera matrices.
`RTBENCH_SCENARIO=denoise [RTBENCH_PRESET=Performance@3] tools/rtbench pt`, then `scripts/passcost_report.py <run>`
(time frozen at the save's position, each mode twice, drift corrected).

Frame interval (ms, median of 180 frames; summed command buffer GPU time overstates the denoised scaler because frames
overlap on the GPU):

| MetalFX preset (input, output 1168x730) | off (NRD + temporal scaler) | pass | fx | fx saves |
| --- | ---: | ---: | ---: | ---: |
| Quality (779x487) | 15.6 | 13.6 | 14.9 | 0.70 |
| Balanced (687x429) | 14.4 | 12.5 | 13.8 | 0.55 |
| Performance (584x365) | 11.9 | 10.8 | 11.7 | 0.18 |

- RELAX costs 1.1-2.0 ms of a path traced frame; the denoised scaler costs 0.9-1.3 ms in its place: no overhead.
- Still images (time frozen): pass is grainy, fx is clean and close to NRD; fx at Performance (11.7 ms) looks close to
  the game at Quality (15.6 ms). Motion (ghosting, disocclusion) is not tested yet.
- `Developer/FeatureToggles/DLSSD` (the game's Ray Reconstruction path, `m_rayTracedReference_DLSSD_*` shaders) set to
  1 changes nothing on macOS: NRD still runs, and the upscaler options are Off, FSR2, FSR3 and MetalFX only.

## RT Ultra, camera matrices and motion (2026-10-08)

- **RT Ultra RELAX:** diffuse (encoder: PrePass 2146613912, TemporalAccumulation 471566690, HistoryFix 3056446971,
  HistoryClamping 3324492930, AntiFirefly 258640069, AtrousSmem 610715217, four a-trous 1741889550) and specular
  (PrePass 2571244900, TemporalAccumulation 2320542953, HistoryFix 871526259, HistoryClamping 1863037915, AntiFirefly
  482482882, AtrousSmem 2465595461, four a-trous 3863891985). Several order-only names in these encoders are wrong
  (`m_distortion_11`, `m_computeShadingRateImage_TileSize16`). Each PrePass writes one full resolution RGBA16Float (the
  checkerboard resolved); the last a-trous pass writes the output. Denoise mode, RT Ultra at Quality (frame interval):
  pass saves 1.14 ms, fx costs 0.47 ms more than NRD (RELAX is cheaper here than in path tracing).
- **Root arguments:** the top-level argument buffer (index 2) lives in a 128 MiB shared upload ring; its entries are
  addresses of descriptor tables in a 32 MiB shared descriptor heap (both heap buffers); Metal Shader Converter
  descriptors are 24 bytes, the buffer address first. RELAX's root entry 0, descriptor 6, is NRD's constant buffer
  (RELAX shared constants, column-major): gWorldToClipPrev +0, gWorldToViewPrev +64, gWorldToClip +128,
  gWorldPrevToWorld +192, gViewToWorld +256, frustum vectors +320, gCameraDelta +416, resource size +496. The engine
  renders camera-relative: gViewToWorld has no translation; walking shows up in gCameraDelta.
- **Motion** (`RTBENCH_SCENARIO=motion`, PSNR of the first still frame after a 1.2 s walk against 90 frames later,
  higher is better; three runs):

  | Run | off (NRD) | fx, game matrices | fx, identity | fx, right-handed |
  | --- | ---: | ---: | ---: | ---: |
  | path tracing 1 | 34.3 | 35.7 | 37.2 | 37.2 |
  | path tracing 2 | 34.8 | 35.5 | 34.7 | 35.5 |
  | RT Ultra | 37.3 | 41.1 | 38.8 | 39.7 |

## Apple's denoised scaler: cost (`build/denoiser_bench`, 2026-10-08)

`MTLFXTemporalDenoisedScaler` against the plain `MTLFXTemporalScaler`, M4 Max, idle GPU, game formats (color
RGBA16Float, depth Depth32Float, motion RG16Float, BGR10A2 albedos, RGBA16Float normals, R16Float roughness and
specular hit distance), synchronous initialization, median of 200 frames:

| Input | Output | Temporal scaler ms | Denoised scaler ms |
| --- | --- | ---: | ---: |
| 779x487 | 1168x730 | 0.11 | 1.76 |
| 1152x720 | 1728x1080 | 0.24 | 3.43 |
| 1280x800 | 2560x1600 | 0.40 | 4.96 |
| 1728x1117 | 3456x2234 | 0.77 | 9.40 |
| 2304x1489 | 3456x2234 | 1.13 | 15.01 |
| 1920x1080 | 1920x1080 (denoise only) | 0.50 | 7.67 |

Formats and options barely matter (8-bit guides, no hit distance, auto exposure: within 0.05 ms; the game's
Depth32Float_Stencil8 depth adds 0.17 ms). Cost is about 3.2 ms per million input pixels plus 0.6 ms per million output
pixels: 1.28 ms at 584x365 and 0.84 ms at 389x243 to 1168x730.

The denoised scaler costs about 4.5 ms per million input pixels, roughly what NRD and its surrounding passes cost in
RT Ultra (2.6-7.9 ms per million at 779x487) and less than in path tracing (4.5-9.8 ms per million). Replacing NRD and
the temporal scaler with it is therefore about break-even in RT Ultra and saves up to about 2 ms at 779x487 (5 ms at
1080p output) in path tracing. The case for the swap is image quality (one denoiser trained for upscaled, ray traced
input), and frame time only in path tracing.

## Corrections to earlier notes

- The "denoiser candidate" pipelines of the retired tracer (2024x847 motion and depth, 1720x720 history, 3440x1440
  output) were MetalFX's own temporal upscaler kernels, not the game's denoiser.
- Pixel format numbers were mislabeled: 13 is R8Uint, 23 R16Uint, 30 RG8Unorm (not R8Unorm / RGB10A2), 62 RG16Snorm,
  94 BGR10A2Unorm.

## Open

- Decode the top-level argument buffer per dispatch (root signature to descriptor heap indices) to name each
  dispatch's exact textures; this is what maps NRD's inputs (normal/roughness, view Z, motion, hit distance) and
  outputs.
- Name the 174 order-only and 47 unnamed static kernels (the extra keys of multi-permutation records).
- Settings changed at runtime (UserSettings) read back as changed but do not switch the ray tracing renderer; rtbench
  therefore sets each mode before launch.
