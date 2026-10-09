# MetalFX Denoiser: Status

> **Last updated:** 2026-10-08
> **Target:** Cyberpunk 2077 macOS 2.3.1, Apple silicon, RED4ext for macOS
> **Status:** working denoiser (path tracing and RT Ultra/Psycho), player setting in ModMenu and config.toml

## What works

- The plugin builds, loads under RED4ext, reads `config.toml`, and creates a MetalFX context. It changes nothing in
  rendering.
- Native Metal tracer (`METALFX_TRACE=1` or `[debug] trace_metal_compute = true`): pipeline names and reflection,
  one-frame traces, GPU frame timings, one-frame GPU captures (`MTL_CAPTURE_ENABLED=1`). Checked by
  `build/trace_selftest` and in game.
- RED4ext `tools/rtbench`: raster, RT Ultra, RT Psycho and path tracing at 5 spots, in the background. Findings and
  numbers: `PIPELINE_TRACE_FINDINGS.md`. Settings: `CONFIG_VARS.md`.

## Goal (2026-10-08): path tracing that feels like 60 fps

Path tracing at native 3456x2160 (fullscreen, M4 Max) at about 16.7 ms per rendered frame; frame interpolation only as
smoothness on top. Starting point: about 50 ms (20 fps) with the Apple denoiser at MetalFX Performance. The plan is the
"Path to 60" list at the end of this file.

Where it stands (2026-10-08): path tracing at a 3x scale (1152x720 -> 3456x2160) with the Apple denoiser renders at
27-32 ms; with frame generation 33-37 ms rendered and 48-60 fps displayed, which the player rates good and fairly
smooth. Rendered 16.7 ms remains open (see "Path to 60").

## Where this stands against the goal

Goal: more FPS and better image quality by replacing the game's denoisers (NRD REBLUR/RELAX/SIGMA) and its temporal
upscaler with Apple's `MTLFXTemporalDenoisedScaler` (macOS 26, supported on M4 Max).

What the tracing work settled:
- **What would be removed:** the denoiser passes are now named in every trace (verified names). RT Ultra runs RELAX
  (diffuse and specular: prepass, temporal accumulation, history fix and clamping, anti-firefly, a-trous), REBLUR
  (directional occlusion, specular history) and SIGMA (shadows); path tracing adds SHaRC and ReSTIR GI.
- **Where the replacement goes:** the game's MetalFX temporal scaler call, whose color (RGBA16Float), depth
  (Depth32Float_Stencil8, reversed Z) and motion (RG16Float, UV units) inputs the tracer already captures. The denoised
  scaler also needs diffuse/specular albedo, normals and roughness (G-buffer, not mapped yet) and the noisy lighting
  before denoising.
- **The baseline:** the upscaler option's index decides the upscaler (index 1 is MetalFX); all rtbench runs before
  2026-10-08 measured FSR3.

Measured: ray generation is 4.6 ms of an 11.3 ms RT Ultra frame (passcost); NRD and its surrounding passes are
1-3 ms in RT Ultra and 1.7-3.7 ms in path tracing (`RayTracing/DenoisingShaderPreferenceAAPL=0` removes them, but
also the lighting they output, `CONFIG_VARS.md`). So the swap can save 10-20% of the frame if the denoised scaler costs
less than NRD. Its input must be the noisy lighting composited as if NRD had passed it through. NRD's debug split
screen (`Editor/Denoising/NRD/DebugSplitScreen=0.5`) is reachable and its SplitScreen kernel then runs in path tracing,
but no noisy half was visible in motion (rtbench `-split`, 2026-10-08): not a usable pass-through yet.

## Next steps

1. **Done: frame cost by part** (passcost): ray generation 41%, NRD 9%, refits under 5%, MetalFX 1% in RT Ultra.
1b. **Done: runtime access to the engine's settings** (`CONFIG_VARS.md`): 190 ray tracing variables verified in
   RED4ext's address DB, read and written by this plugin; live changes reach the renderer (half resolution tracing
   toggles change RT Ultra by 1.2-1.5 ms). Next: the path tracing cost knobs (SHaRC bounces and downscale, multilayer
   resolution scale, ReSTIR GI samples), with image comparisons, not only timings.
2. **MetalFX baseline:** rtbench with MetalFX selected, on an idle Mac, several timing windows per spot.
2b. **Done: the denoised scaler's cost** (`build/denoiser_bench`, `PIPELINE_TRACE_FINDINGS.md`): 1.76 ms at 779x487,
   about 4.5 ms per million input pixels. That is about NRD's cost in RT Ultra and less than NRD in path tracing: the
   swap is about quality in RT Ultra, and saves up to about 2 ms (779x487) in path tracing.
3. **Inputs:** done for the G-buffer (`PIPELINE_TRACE_FINDINGS.md`: base color, world-space normals, metalness,
   roughness; the in-game dump now writes every multi-target render pass). Left: specular hit distance and the noisy
   lighting, which compute passes write through the descriptor heap: dump the textures NRD's first passes read
   (their `useResource` reads), or decode the descriptor heap.
   Done for NRD's own inputs (`PIPELINE_TRACE_FINDINGS.md`, "NRD's inputs"): the noisy diffuse and specular radiance
   are half width checkerboards with hit distance in alpha; view Z and NRD's normal/roughness are known textures.
3b. **NRD pass-through:** make NRD hand its noisy inputs to the composite (split screen at 1.0, or replacing the NRD
   dispatches with copies once their input and output textures are known), so the denoised scaler gets a noisy but
   complete image.
4. **Done: path tracing prototype** (`src/plugin/Denoise.mm`, `PIPELINE_TRACE_FINDINGS.md`): RELAX dropped and
   passed through, MetalFX's denoised scaler in place of the temporal scaler. 0.2-0.7 ms faster than the game's NRD
   path at the same preset; at Performance it is 25% faster than the game at Quality with a similar still image.
   Next: motion tests (rtbench flicker, ghosting), camera matrices (identity now), RT Ultra (half width checkerboard
   inputs), and making the mode a player setting.
4b. **Done (2026-10-08): RT Ultra, camera, motion, player setting.**
   - RT Ultra/Psycho: diffuse and specular RELAX each run in their own encoder; their PrePass (kept) resolves the half
     width checkerboard; everything after it is dropped and the PrePass output copied to the final output.
   - Camera matrices from NRD's constant buffer, found through Metal Shader Converter's root arguments and descriptors
     (MetalTrace keeps the game's large shared heap buffers readable); conventions: `denoisecam game|identity|rh`.
   - Motion: `RTBENCH_SCENARIO=motion` + `scripts/motion_report.py` (first still frame after walking vs converged).
     fx recovers at least as well as NRD in path tracing and better in RT Ultra; the camera conventions are within
     run-to-run noise (about 1.5 dB), so the game's matrices stay.
   - Player setting: `config.toml` `[metalfx] enabled`, ModMenu page (saved choice wins), `[debug] noisy_lighting`.
     fx only passes RELAX through while the game calls its MetalFX upscaler (FSR or no upscaling keep NRD).
   Next: RT Psycho check, quality presets (denoiser at Performance by default?).
4c. **Black smears at the screen edges while turning (player report, path tracing, 3456x2160 at a low frame rate).**
   Not reproduced by the scripted tests (`turn`: teleport-driven turns and flicks at 1168x730, mid-turn "shot"
   captures; the motion trigger and frozen-time teleports made frame-exact captures unreliable). Likely cause: at low
   frame rates each frame uncovers a wide band at the edge whose raw path traced signal is nearly black, and the stock
   denoiser hides it with RELAX's PrePass and HistoryFix. Path tracing now keeps RELAX's PrePass by default
   (`denoiseprepass on|off`), as RT Ultra already did. Player check (3456x2160, Performance): edges fixed.
4e. **Fixed: pale white skin and washed-out colors in path tracing (player report).** The path tracing PrePass's two
   outputs are allocated specular first, so pairing them with RELAX's outputs by address swapped diffuse and specular
   (since the PrePass default of 4c). Reversed (`kChains` in Denoise.mm), the image is the closest to the game's NRD of
   all variants: `RTBENCH_SCENARIO=skin` at Kabuki Market, mean error against NRD 4.4 (was 14.2; raw input 4.8).
   RT Ultra's separate diffuse and specular PrePass outputs were already right (3.2).
4d. **Fixed: stutter growing over minutes, a load that never finished.** The buffer registry recorded every buffer
   the game created (metadata plus a lock on buffer creation) and grew without bound while streaming; with the
   denoiser on from boot a load sat on the loading screen for 15 minutes, and a play session started stuttering after
   two. It now records only the large shared heap buffers the camera read needs (2 buffers, 158 MiB, flat over 21,600
   frames of rtbench; loads normally).
4a. **Original plan:** create `MTLFXTemporalDenoisedScaler` where the game creates its MetalFX scaler, feed it the mapped
   textures, skip NRD; compare against step 2 (GPU time, flicker, screenshots).
5. **Settings:** once the registry is reachable (1b), measure the hidden settings (half resolution tracing, path
   tracing rays and bounces, the Apple denoiser masks) with passcost and rtbench.

## Path to 60: progress (2026-10-08)

- Step 0 done: per-encoder GPU profiler (`profile`), play-time frame log, native resolution runs in a background
  window. Native path tracing at Performance: 50 ms, GPU-bound (PIPELINE_TRACE_FINDINGS.md has the breakdown).
- Step 1: the redundant raster features (FeatureToggles) are each within noise: not a lever.
- Step 2 done, the big one: the engine's hidden 3x MetalFX scale (`MFX/OverrideEnable=1`, `MFX/Quality=4`) switches
  at runtime: 49.8 to 27.7 ms (stock denoiser), 28.2 ms with the Apple denoiser, at 3456x2160. Softer image. Player
  setting: `[metalfx] ultra_performance`, ModMenu "Ultra Performance".
- Remaining at 3x: path tracing 7.1, NRD 4.3, raster 3.1, RTXDI 3.1, other compute 2.7, ReSTIR GI 2.0, copies 1.9,
  MetalFX 1.3, the rest about 4 ms. 16.7 ms needs another 11 ms.
- At 3x the Apple denoiser (its MetalFX passes plus about 2.6 ms of neural network convolutions, 5.4 ms) still costs
  what RELAX plus the MetalFX upscaler cost (5.6 ms).
- Path tracing settings (16 profiled experiments at 3x, `experiments/pt-knobs-*.txt`, `scripts/profile_diff.py`): one
  frame per setting is too noisy (frames differ by about 1.5 ms; acceleration structure encoders show 1-11 ms spikes
  in profiled frames, likely a timestamp artifact of the descriptor path, not seen in timing windows). Consistent only
  in the path tracing pass itself: SHaRC bounces 2 (default 4) about -1.1 ms, SHaRC downscale 8 (default 5) about
  -0.7 ms. Settings are worth 1-2 ms, not 11.
- Copies at 3x are mostly clears: 68 buffer fills, 472 MiB per frame, about 1.5 ms (render resolution buffers at
  4-120 bytes per pixel and a 64 MiB table). Skipping a clear is only safe if the buffer is fully rewritten first.
- Native 3456x2160, frame interval (scale scenario): path tracing 49.8 ms at Performance, 27.7 ms at 3x (28.2 with
  the denoiser); RT Psycho 38.8 / 22.4 ms; RT Ultra 41.1 / 22.9 ms. At 3x even RT Ultra is 23 ms: about 12 ms of the
  frame is not ray tracing (raster, post-processing and the upscaler at the 7.5 MP output, clears, lights), so 16.7 ms
  rendered at native output is out of reach on this Mac for path tracing and for RT.
- Outlook: path tracing about 24-26 ms (40 fps) with the remaining small wins; RT about 21 ms. Feeling 60 needs a
  lower output resolution or a lighter mode; MetalFX frame interpolation adds smoothness, not responsiveness.

- **Frame generation (2026-10-08, `FrameGen.mm`):** MetalFX frame interpolation between every two presented frames
  (the game's final RGBA16Float swapchain images with HUD; depth and motion copied at its MetalFX call; near plane, field
  of view and aspect from NRD's constants). The generated frame goes into an extra drawable, presented first; the game's
  frame follows half a frame interval later (presentDrawable:afterMinimumDuration:). Interpolator 3.1 ms at
  1152x720 -> 3456x2160 (bench); in game path tracing at 3x goes from 29.1 to 33.9 ms per rendered frame (the copies
  and the readable swapchain included): about 29.5 rendered fps, about 59 displayed. 240 of 240 presents generated.
  Displayed pacing can only be judged on screen (a covered window reports no presented times). The HUD is
  interpolated with the scene (no separate UI texture). Player setting `[metalfx] frame_generation`, ModMenu toggle.
  First fullscreen play: a frame every 1-10 s. Taking the second drawable from the game's own layer (three drawables)
  starved it in fullscreen, where nextDrawable then waits up to its one second timeout (a covered window, as in the
  background tests, gives drawables back at once). Fixed: frames are shown through an overlay layer of our own (a
  sublayer with the game's format and EDR settings and its own drawables); the game's drawables are never presented
  and go back to its pool. Safety valve: three overlay drawable waits over 50 ms in a row turn it off. Background
  test after the fix: 240 of 240 presents generated, 33.5 ms per rendered frame.
- **Player report (3x path tracing, Apple denoiser, no frame generation):** very stable, good performance, very good
  graphics; the 3x scale is only slightly noticeable. 27-32 ms per frame in play.
- **Player report (3x path tracing, Apple denoiser, frame generation, fullscreen, after the overlay fix):** good, fairly
  smooth. Play log (two minutes in the world): 240 of 240 presents generated in every window, no drawable waits, the
  safety valve never fired; 33-37 ms per rendered frame (GPU-bound, p95 about 42 ms), against 27-32 ms without frame
  generation; displayed interval median 16.7 ms (60 fps) in most windows and 20.8 ms (48 fps) in heavier scenes, p95
  29-34 ms. The display runs at 120 Hz, so intervals land on multiples of 8.3 ms. At the start screen and in menus the
  game does not call MetalFX, so frames pass through ("stale inputs").

## 3x image quality (2026-10-08)

Player report at 3x with frame generation: jagged edges, overly smooth textures, blocky in motion (only in motion,
only with frame generation). Measured:
- **Jitter:** the game already uses 72 jitter phases at 3x (8 x 3^2, as recommended for a temporal upscaler).
- **Engine knobs do nothing here:** `Editor/MipBias/*`, `MFX/Sharpness`/`OverrideSharpness`, the CAS toggle and
  `FSR2/EnableHalton`/`SampleNumber` changed nothing measurable (cvarbatch `experiments/pt-quality-a.txt`, several
  variables per experiment now joined by ';'). The denoised scaler replaces the game's MetalFX call, so the game's own
  sharpening never runs.
- **Samplers:** every sampler the game creates has LOD bias 0 (any mip bias lives in its shaders). Adding -0.585
  (2x to 3x) at creation: 2.5-4% more detail (Laplacian), slightly crisper textures. Setting `texture_lod_bias`
  (applies at game start).
- **Sharpening:** RCAS after the denoised scaler (in a reversible tone-mapped space, limited lobe, no halos). Detail
  0.0156 at 0, 0.0170 at 0.25, 0.0193 at 0.5, 0.0234 at 0.75, 0.0333 at 1; 1 sharpens noise into grain, 0.3-0.5 is
  the useful range. Setting `sharpness`, ModMenu slider; cost within frame noise.
- **Frame interpolation quality** (`FrameGen::Evaluate`, request `fgeval <n>` in the framegen scenario's turn,
  `scripts/fgeval_report.py`): a second interpolator on every other frame interpolates N-2 to N and is compared with
  the real N-1. During a steady 1 degree per frame turn: 50-54 dB (repeating N: 31 dB, averaging N-2 and N: 33 dB).
  The render jitter scores about 0.6 dB above jitter 0. Normal-path generated frames sit symmetrically between their
  inputs. A turn has no parallax; blockiness in play likely comes from disocclusion and parallax at render-resolution
  motion vectors and from the HUD being interpolated with the scene. After a reset the interpolator returns its color
  input for two calls (the first test version, which reset every call, measured nothing).
- Test-tool fix: PNG dumps are converted off Metal's completion thread (4K conversions there held up the game's
  drawables and tripped frame generation's safety valve).

## Path to 60 (path tracing, 16.7 ms rendered at 3456x2160)

Budget today: about 50 ms. Gains below are estimates until step 0 measures them at native resolution.

0. **Measure at native resolution first.**
   - Frame-time logger in the plugin (frame interval, GPU time, CPU encode time), written during normal play.
   - CPU-bound check: if the CPU frame time is near 16.7 ms, GPU work cannot reach the goal; profile the main and
     render threads.
   - Per-part cost at native resolution (passcost: ray generation, ReSTIR GI, SHaRC, RTXDI, NRD leftovers, denoiser,
     raster G-buffer, shadow maps, post-processing, volumetrics).
   - Plugin overhead: no plugin, plugin with the denoiser off, denoiser on.
   - Sustained performance: power adapter, High Power Mode, thermals over 10 minutes.
1. **Cheap settings wins (hours, 5-20%).**
   - Screen-space and raster effects that path tracing makes redundant, through the verified
     `Developer/FeatureToggles/*` variables: screen-space reflections (the cinematic SSR runs in path tracing), SSAO,
     contact shadows, GI probes and distant GI, cascade and local shadow maps. Image check for each.
   - The rest of NRD in path tracing (SIGMA, REBLUR occlusion, input preparation, hit distance reconstruction): 3-10%.
   - Crowd density and other CPU-side settings if step 0 shows CPU limits.
2. **Render less (days, 20-40%).**
   - A render scale below Performance, down to the denoiser's 3x (1152x720): the plugin sets the game's render size,
     or the game's dynamic resolution (MetalFX "Dynamic", `DRS_TargetFPS`, min/max percentage) targets 60 fps. The
     denoised scaler has no input content size, so dynamic resolution needs a fixed-size crop or a recreate.
   - Denoise and upscale to a lower output (for example 2560x1600), then MetalFX's spatial scaler to 3456x2160: saves
     the denoiser's output cost (about 0.6 ms per million output pixels, 2-3 ms here).
   - Quality guardrails for each: motion, turn, skin and reference scenarios.
3. **Trace less (days to weeks, unknown, possibly large).**
   - Systematic sweep of the path tracing variables (rays per pixel, bounces, SHaRC, ReSTIR GI, RTXDI samples and light
     counts, wavefront and SER options, ray tracing culling distances) with cvarbatch, timing and image error per
     setting; earlier single tries showed no effect, so map which ones are live first.
   - Half resolution for parts of the path tracer (indirect or specular), with the denoiser filling in.
   - Acceleration structures: refits (0.3 ms), instance culling by distance.
4. **Shader and GPU level (weeks).**
   - Profile the wavefront tracing and shading kernels (occupancy, Metal Shader Converter bindless overhead,
     alpha-tested geometry), from one GPU capture at native resolution.
   - Metal 4 MetalFX (MTL4FX denoised scaler) cost check.
5. **Smoothness on top (days).** MetalFX frame interpolation once the rendered frame rate is near 40-60, for 120 Hz
   display smoothness (it does not improve responsiveness).
6. **Keep it shippable.** Long-session soak (memory, stutter), the skin/motion/turn regression scenarios after each
   change, ModMenu entries for the new options, fail-closed defaults.
