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

## Render scale between 2x and 3x (2026-10-08)

The game's resolution settings stop at 50% (DRS_MinResolution 50-100), so scales above 2x exist only through the
engine's scale table. It is now a verified address DB entry, "Upscaler/ScaleTable" (RED4ext.SDK
scripts/upscaler_scale_table.py: the 16 bytes [1.5, 1.7, 2.0, 3.0] occur once in __TEXT,__const; six ADRP + ADD
references in the upscalers' code). `ConfigVars::SetUltraScale` rewrites its fourth entry (quality 4, reached only
through MFX/OverrideEnable + MFX/Quality=4), after checking the table in memory, with a copy-on-write page protection
change (the 16 KB page holds only constants). It takes effect on the next frame. Setting `ultra_scale`, ModMenu slider
(2 to 3 in steps of 0.25), request `ultrascale <scale>`, scenario `ultrascale` (RED4ext).

Path tracing with the denoiser, no frame generation, frozen spot:

| Scale | Render size | Frame | GPU busy |
| --- | --- | ---: | ---: |
| 3 | 1152x720 | 28.3 ms | 47.5 ms |
| 2.75 | 1257x785 | 31.7 ms | 53.2 ms |
| 2.5 | 1382x864 | 37.5 ms | 63.4 ms |

Player report at 3x with sharpening 0.4, texture LOD bias -0.585 and frame generation: looks great, very smooth.

## Frame generation HUD (2026-10-08; player-verified 2026-10-09: fixed)

Player report at 2.5x: the HUD ghosts in motion. Measured with `fgeval`: in the HUD regions the interpolated frame
scores 28.6 dB against the real in-between frame, worse than repeating the frame (32.7 dB). The game draws the HUD into
an output-size RGBA8 sRGB layer with alpha (5 passes a frame, found by `FrameGen::RenderPass`) and composites it into an
RGBA16F target before its last pass; there is no scene-without-HUD image in display space. MetalFX's own UI input does
not fit: `uiTextureComposited` returned black even with an empty UI texture (standalone test). Fix in place: after
interpolating, the generated frame is copied and the HUD's pixels (layer alpha, dilated, boosted) are taken from the
real frame (`WithHud`/`RestoreHud`; METALFX_FG_UI=0 turns it off). A compute pass on the interpolator's output itself
lost its writes in the game (standalone it worked), hence the copy. Not yet verified: the last test run hung when the
game took focus. Plugin GPU work now bypasses the hooks (`MetalTrace::Internal`).

## Frame warp (2026-10-09, removed)

- Tried and removed (commits 1ef7bae, 8612718, reverted): re-aiming frames to the newest mouse input before display.
  Findings kept: gViewToWorld column 2 is forward, column 1 up; the game turns the camera by 0.873 mrad per AppKit mouse
  count; it reads input on its main thread about 10 ms before its present call, so a game-thread input delay has no
  slack to remove; most input lag is after the present call (about 76 ms to the display in play).
- HUD ghosting: the interpolator works on shown frames, which contain the HUD and its glow. Two plugin-side fixes
  tried and reverted (988b7b7, 4fd27fa). The game's FSR3 frame generation (the Mac build's other option) is worse.
- Root cause of the ghost copies (2026-10-09): the game draws them on purpose. The HUD composite m_hud_occupiedTiles
  (label 3959251910; IR from the shader cache with metal-objdump) samples the UI layer at uv and at uv +- k*d (R and B,
  chromatic aberration) and adds blurred copies at further offsets (UI mips 1, 2, 4), all along d = the radial vector
  from the screen centre after a barrel distortion; the whole block is gated by constant buffer float 16 (descriptor
  6 of the first table), strengths at 108 and 112-140, distortion at 48/52. CDPR's "Remove HUD Visual Effects"
  (Settings > Accessibility > Interface; UserSettings /accessibility/interface/PostProcessingReduction) removes "the
  chromatic aberration effect, also known as 'ghosting', in the HUD" (cyberpunk.net update 2.1 accessibility notes);
  "Remove HUD Lens Distortion" is LensDistortionOverride. Frame interpolation smears these soft copies further.
- Measured in play (2026-10-09) with Remove HUD Visual Effects and Remove HUD Lens Distortion on (set in
  UserSettings.json; toggling in the menu had not been saved): the composite's distortion and aberration constants
  are 0, ghosting without frame generation is gone. The switch at float 16 gates the whole HUD draw (zeroing it hid the
  HUD; that toggle is reverted). Soft offset copies stay (UI mips 1, 2, 4 at offsets of up to 1.3% of the screen,
  about 40 px): the HUD restore mask now also covers the UI layer's 16x mip widened by one texel (about +-32 px).
- Why the HUD restore never worked in play (found 2026-10-09 in saved frames): a run with the debug paint showed the
  restore saw no HUD at all (every generated pixel green), and a normal run restored only 62-70% of fully opaque HUD
  pixels, while a copy of the same UI layer in the same command buffer showed the whole HUD. At present time the
  game's UI layer is already being cleared and redrawn for the next frame (its resources are not hazard tracked). Fix:
  FrameGen::HudComposite snapshots the UI layer's alpha (level 0 and the 16x mip) inside the game's HUD composite
  encoder (m_hud_occupiedTiles, via Denoise's encoder hooks), and the restore reads the snapshot. Self-test: a
  composite stand-in with a 2D array, mipmapped UI layer; the debug paint covers 2048 of 2048 pixels.
- Measured in game after the snapshot fix (cp-run framegen, fgeval saves of the generated frame, the real frame and
  the snapshot): HUD pixels in generated frames equal the real frame on 100% (3 samples, about 215,000 px each), up
  from 62-70%; soft edges and the halo went from 86% to 100% once any coverage takes the real pixel whole instead of
  blending. scripts: compare fgnormal<i>-gen against -cur over -uisnap.
- If ghosting remains with that setting on and frame generation on: Apple's intended wiring for a composited HUD
  (WWDC25 211) is colour/prev colour = the HUD-less scene, uiTexture = the shown image, isUITextureComposited = YES.

## Input lag with frame generation (2026-10-09)

- Frame queue limiter tried and dropped. A CPU-ahead limit at the presenting commit (wait for frame N-1's GPU end;
  optionally a just-in-time start delay) cut frame start to GPU done from 565 to 21 ms in a GPU-bound offline loop, but
  the game already keeps one frame in flight: in game (path tracing, 2.5x, frame generation) mode 0 measured 1.0 frames
  in flight, 68 ms frame start to GPU done, 42 ms frames; one frame queued gave 76 ms and 47 ms frames, just-in-time 75 ms
  and 59 ms frames. Nothing to drain at the GPU queue; the code is not kept.
- Frame generation pacing rounded down to whole refreshes (ed1f2f4): reverted with frame warp; the hold is half a
  frame interval again.
- What remains: input lag follows the rendered frame time (frame generation adds about 5 ms of GPU time per frame and
  holds the real frame about half a frame). Render scale 3x instead of 2.5x saves about 10 ms per frame.
- Plugin log: now red4ext/plugins/MetalFXDenoiser/metalfxdenoiser.log; RED4ext's log rotation deleted it in
  red4ext/logs (names that do not start with a plugin's name).

## Toward 120 fps displayed (2026-10-10)

Setup measured: RT Psycho, Ultra Performance 2.25x (1536x960 -> 3456x2160), the game's NRD, M4 Max.

- **Frame generation cost** (tests/fg_bench, per rendered frame): 6.3 -> 4.4 ms. The HUD pass writes the generated
  drawable itself (two full-screen copies gone) and tests the UI snapshot's 16x mip once widened (1.66 -> 0.27 ms).
  Left: the interpolator, 3.65 ms at full output, 1.29 ms at half output. In game the 2x overhead read +7 to +9 ms
  across runs (noise about 2 ms; the display was asleep, which changes drawable waits: see below).
- **Multi-frame generation** (frame_generation_multiplier = 4): MTLFXFrameInterpolator only makes midpoints;
  recursive midpoints give 1/4 and 3/4 (tests/fg_phase on an in-game "fgseq" sequence, at four times the motion:
  1/4 43.0, 1/2 41.0, 3/4 44.5 dB at full output; 41.6, 40.4, 41.5 at half; scaled motion vectors do not move the
  phase: 28-30 dB, like repeating a frame). Made at half output and upscaled in the HUD pass; a pacer thread presents
  the four frames whole refreshes apart; three generated frames only when the frame interval allows four refreshes
  (30 fps at 120 Hz), else one. In game: +2.1 ms frame time (33.8 -> 35.9 ms). Presentation is unverified: the
  background runs had the display asleep (every present dropped, 0 shown), so pacing needs a run on a visible display.
- **Dynamic scale** (dynamic_scale_fps): steps Ultra Performance's scale (0.25 steps, ultra_scale to 3.0, at most
  every 2 s; since changed: 10 s, 2 s on the engine's dynamic resolution) to hold a rendered fps. The game's own dynamic resolution stops at 50% (2x). In game with a 40 fps target:
  2.25 -> 3.0 in 4 s, then 25.0 ms frames (p95 25.7). The texture LOD bias stays set for ultra_scale.
- **Path tracing play test (02:12-02:14) was unstable**, three causes from the log: dynamic scale flipped 2.5 <-> 2.75
  every 2-5 s (path tracing 34.8 / 27.9 ms against a 33.3 ms target; each change a 147-172 ms frame and about a second of
  52-62 ms frames: the game resizing its render-size resources; our interpolators rebuild in under 1 ms); 4x flipped
  between three and one generated frames several times a second (each flip reset the interpolators: a repeated frame);
  and at 30 fps the pacer had no headroom (queue delay 25-31 ms, generated frames skipped for 40-78 of 120 frames,
  displayed median 21-23 ms). Fixed: dynamic scale steps rarely (8% over / 15% under by pixel count, 10 s hold, no
  step back down within 60 s of a step up); 4x always interpolates all three phases, switches on a 1 s average with
  15% / 5% margins at most every 3 s.
- **For 120 Hz:** the game's frame cap at 30 fps (MaximumFPS), a fixed ultra_scale that renders under 33 ms (path
  tracing: 2.75, about 28 ms), frame_generation_multiplier = 4: the four frames fill each 33.3 ms exactly.
- The interpolator's fence property stopped the game's rendering in both runs that used it (not used).

## Input lag (2026-10-10)

- **Latency meter** (Input.mm): the game's event pump is hooked again (read only); each game frame's newest mouse event
  is timed to the moment its frame is shown (presented handler), per path (off, 2x, 4x), with three parts: event to the
  game's read, read to present call, present call to display. Logged every 120 frames with mouse movement ("Latency").
  Needs a visible display (background runs never show a frame).
- **4x pacer rework.** Found in game (path tracing): the 4x path had no back-pressure (the game's drawables are never
  presented, so nothing held it back), so the game ran up to three frames ahead of the GPU (frames shown about 130 ms
  after their present call) and, chained present to present, the pacer ran a frame behind at 30 fps. Now: the present
  call for frame N waits for frame N-1's GPU work (one frame queued); each frame's presents start when it is ready (the
  first at once, the rest whole refreshes apart); the rest of a frame is dropped only once a newer frame is ready. In
  game: 3.8 presents per rendered frame, 2-47 of 120 frames cut short.
- **Generation off the game's queue** (pacer queue, request "fgqueue game|own"): with path tracing the GPU is saturated,
  so it changes nothing (48.3 vs 48.4 ms frames, same run); it can use idle GPU time under a cap. Kept on the pacer's queue.
- **Frame limiter before the input read** (frame_limit_fps; request "framelimit"): waits at the game's first event pump of
  a frame, so the frame starts from fresh input; use it instead of the game's Maximum FPS. 29 for 4x at 120 Hz.
- 4x costs about 6-7 ms per frame with path tracing (41-43 -> 48 ms, GPU-bound).
- **Camera warp** (camera_warp, 4x; Warp.mm): each shown frame is turned to the game's mouse input at its display time
  minus the input lead (the 90th percentile of display time minus the newest mouse event, about 60 ms), by the
  events' own timestamps, so turns show up about a frame sooner and stay smooth. Rotation only, at most 4 degrees,
  HUD unturned; calibrated live (camera turn between frames against the game's mouse counts between them): in game
  with synthetic turns -0.82 / -0.85 mrad per count, R2 0.83-0.94 (0.873 measured before); off while the fit is poor.
  The camera comes from NRD's constants, so the warp turns Denoise's hooks on (its watch mode) also with the Apple
  denoiser off. Check (warpcheck, scripts/warpeval_report.py): a warped game frame is closer to the next game frame
  than the frame itself in 8 of 8 pairs, 19.2 -> 23.2 dB. Cost: none measurable (HUD pass 0.31 ms either way).

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

## Bool config variables (2026-10-10)

- **Fixed: bool config variables were read and written at the wrong byte.** The live value is at +0x29 (+0x2c is the
  default; DRS_RECON.md §3.3). Every earlier bool experiment changed only the default and measured nothing: the CAS
  toggle, `MFX/OverrideSharpness`, `FSR2/EnableHalton`, the FeatureToggles ("each within noise"), `SkipStaticMeshes`,
  `EnableNRD`. Those results need repeating. Int and float variables were right.
- Check (`experiments/bool-check.txt`, path tracing at 3x, game MetalFX): screenshot PSNR against the baseline is
  36.5 dB for `EnableCustomMipBias=1` with bias 0, and 37.9 dB for CAS off, against 39.8 dB for two identical baselines
  (noise floor).
- Background runs with 4x frame generation on from the start (the installed config) hung twice after the load. No
  thread was stuck in plugin code. The game sat in its inactive-window loop (`0x103d9936c`: Sleep(33) and no frame),
  right after the pacer reported 480 presents with 0 shown. Not yet understood. Background tests set frame generation
  through requests or keep it off.

## Dynamic scale on the engine's dynamic resolution (2026-10-10, P1 of DRS_RECON.md)

- The game's DRS is switched by the hidden setting `/graphics/presets DynamicResolutionScaling` (menu index: none;
  `0x10169abcc` passes it to the viewport, +0x128), not by MetalFX "Dynamic". On its own it still reallocates: each DRS
  size made a new MetalFX scaler with content properties off (runs 2026-10-10 19:23, 19:28).
- MetalFX's dynamic mode (upscaler state `renderer+0x7680` +0x1a) is set only for a viewport quality no menu value
  reaches. With it, the engine's MetalFX node keeps one scaler with content properties and copies each frame's content
  into it.
- EngineDrs.cpp hooks DRS::Update (address DB "DRS/Update", verified by RED4ext.SDK scripts/drs_update.py, which also
  verifies "Renderer/Global"): while dynamic_scale_fps runs it sets the render size from DynamicScale, widens the floor
  to 3x, caps the allocation at ultra_scale, and turns MetalFX's dynamic mode on. Denoise skips frames with a content
  rectangle (the denoised scaler has none); FrameGen snapshots only the content rectangle.
- Measured (path tracing, dynscale scenario, 3456x2160): step 2.75 -> 3.0, slowest of the next 30 frames 45.3 ms
  (scale table path: 111-172 ms); one scaler for the run (1257x786, content properties on); 3x frame 34.6 ms, as with the
  fixed 3x (34.5 ms). Uncapped (DRS maximum 100%), the scaler was native size and the 3x frame 36.5 ms.

## Frame generation: hang, HUD band, vehicles, 4x sharpness (2026-10-10)

- **Hang:** both hangs (4x on from launch, background runs) came with every present of ours unshown (display asleep or
  window hidden); the game then sat in its inactive-window loop (Sleep(33), no frame, 0x103d9936c), no thread stuck in
  plugin code, no GPU error. With the window visible, a full cvarbatch with 4x ran through (442 of 443 presents shown).
  Now frame generation pauses after 90 unshown presents in a row and lets the game present its own frames, and resumes
  when one of those is shown (METALFX_FG_KEEP_UNSHOWN=1 keeps it on for background tests). Also new: a stall watchdog
  (pacer stage, queued jobs, slots, event values when the game has not presented for 3 s) and command buffer errors in
  the log.
- **HUD band in fast turns:** every pixel near the HUD (3x3 coverage, the 16x mip's +-32 px, the soft copies' offsets,
  and the scene's motion path, which grows with the turn rate) took the real frame's pixel at p: another moment, and
  not turned by the camera warp. Now only HUD pixels do; around them the real frame is reprojected to the generated
  frame's phase, p - (1 - phase) m (in-game frames: the previous frame from the real one this way 46-47 dB, holding the
  real frame 30 dB), and turned with the rest. HUD pass 0.29 ms (unchanged).
- **Camera warp per frame:** off when the camera's own turn between the two game frames differs from the mouse's
  prediction (more than 35% + 0.23 deg: steering, recoil, orbiting cameras) or the camera moves faster than 6 m/s
  (vehicles). Warp quality varies between runs (warpcheck +4.0 dB in 8 of 8 earlier, -0.57 dB in 6 of 15 now, with a
  different fit: -0.51 vs -0.82 mrad per count); the player's config has it off for now.
- **4x sharpness pulse:** the half-size generated frames kept 60% of the real frame's edge detail after bilinear
  upsampling (in-game frames, Laplacian), so edges pulsed sharp/soft at the rendered rate; the HUD pass now upsamples
  them with Catmull-Rom: 74%, +3.3 dB.

## Still-image noise flicker with the Apple denoiser (2026-10-10)

Measured with RED4ext's `flicker` scenario: path tracing, render scale 3x, time frozen, frame generation off; three
captures of the upscaler output 2 s apart per round, rounds interleaved A/B/A/B; PSNR between consecutive captures
(higher = steadier).
- Sharpening 0.4: 42.5 / 41.8 / 41.9 / 42.7 dB (mean 42.2); sharpening 0: 43.4 / 45.5 / 43.8 (44.2). RCAS sharpens the
  denoiser's leftover noise: 2 dB more flicker, 21% more change per frame. The player's config is now at 0.
- Render scale 2.5 instead of 3 (sharpening 0): 45.4 against 43.0 dB, for about 9 ms more per frame.
- MetalFX auto exposure (request "denoiseexposure auto", the game passes pre-exposure 1 and no exposure texture): 42.5
  against 43.3 dB, no gain. Not used.
- Background test runs froze when the user's windows covered the game's: the game stops rendering for a fully occluded
  window (its occlusion handler and an occlusionState poll). RED4ext's background mode now reports the window visible;
  the earlier "4x hang" (two background runs) was this, not frame generation.

## Sharper 4x frames, flicker checks, fixes (2026-10-11)

- **Player feedback (2026-10-11 play):** finer image than before but the low render scale is obvious; the HUD bands are
  mostly gone; distortion around car exhausts remains. Render scale now 2.75 (config and ModMenu).
- **The engine DRS hook was not attached in play:** the installed address DB came from RED4ext's SDK submodule, which
  was older than the SDK with DRS/Update; the submodule is bumped (cp-dev installs from it). Now "Engine DRS: hooked".
- **4x detail:** the three half-size generated frames get the detail they lack from the nearer real frame, moved along
  the motion vectors to their moment, where its half-size copy agrees with them (FrameGenHud.h upsample_detail, tau
  0.4). fg_phase on the in-game sequence: edge detail 50-56% -> 75-78% of the real frames (generated at full size:
  84%), PSNR +0.1-0.7 dB; cost within fg_bench's noise. Request "fgdetail on|off".
- **Latency meter:** half its samples were garbage (hours): the presented handler block captured the FrameInput
  reference, which pointed at a temporary. Copied now. Valid samples in play: 4x 71-80 ms mouse to display, of which
  55-60 ms present call to display (waiting for the next real frame, as interpolation must).
- **Specular hit distance** (request "denoisehit 0|1", off by default): RELAX's noisy specular alpha into an R16Float
  texture for the denoised scaler. One of two runs crashed in MetalFX's encode (MPSGraph constant folding) on the first
  frame after a scaler with the hit distance was created; not reproduced offline (40 creations at the game's sizes and
  formats, alone and with another thread creating scalers). Not measured; stays off.
- **The game's CAS does not touch the denoised output:** flicker scenario at render scale 2.75 with CAS toggled
  (`Developer/FeatureToggles/ConstrastAdaptiveSharpening`, applied: logged): captures 2 s apart 45.1-45.3 dB either
  way, and across the toggle 42.7-43.7 dB, the same as across rounds of one setting (43.2). Render scale 2.75 flickers
  less than 3 did (44.2 dB yesterday).
- **Dynamic scale under a frame cap:** frame time is now the interval minus frame_limit_fps's wait, so the cap no
  longer hides room under the target.
- Tests: background runs are muted (cp-run sets MasterVolume 0 and MuteInBackground; settings restored). Shot captures
  are written on their own serial queue (at utility priority 3 of 24 were written in two minutes) without the alpha
  image. cp-gate passes again (the validator took the scale table in __TEXT,__const for a function).

## Exhaust and smoke: reactive mask from the transparencies (2026-10-11)

- **Cause of the "distortion around the exhaust":** the game composites its transparencies (exhaust and tyre smoke,
  steam plumes, glass, light glows) into the scene color with no motion vectors of their own and gives MetalFX no
  reactive mask, so the denoised scaler drags old smoke along the road's motion: smoke with a hard horizontal smear
  edge (docs/img/reactive-exhaust.png, left; the save's car scene, time running).
- **Where:** a dump at the car scene (path tracing, Performance at 2.75) shows six render passes in one command buffer
  with color attachments RGBA16Float (render size) and R8Unorm in any slots (the game leaves gaps) and a Depth32Float
  depth, all on one scene texture: clouds, then the distant plumes, then the car's exhaust and lights.
- **Mask:** the scene is copied before the first of them (before the game's render encoder is made) and after the last
  (at the command buffer's next encoder or commit: copying from the endEncoding hook asserted "A command encoder is
  already encoding", the hooks nest); per pixel, the largest channel change relative to the brighter value, times 2,
  minus 0.04; given to the denoised scaler as reactiveMaskTexture (R8Unorm). Request "denoisereactive on|off|save"; on
  by default. Result: the smoke edge is gone (right half of the image); the mask also covers glass and light bars.
- Two failures on the way, both fixed before the next run: encoding the copy with the denoiser's lock held deadlocked
  (the copy's own encoder hooks take it; GPU timeout), and the copy from inside endEncoding asserted.
- **Generated frames (4x):** the mask goes to frame generation too: in masked pixels, where the two real frames agree
  better unmoved than moved by the motion vector (smoke that stays on screen with the car), the HUD pass blends them in
  place instead of the interpolator's result. Request "fgreactive on|off". Not yet measured in game.
- **Test plumbing:** the plugin read scenario requests only outside its timing windows and one per poll, and a second
  "shot" replaced the first: requests ran seconds late and in bursts. Now all waiting requests run at once, also
  during timing windows, and shots queue.

## 4x in motion: pulse, minimap line, a GPU fault (2026-10-11)

- **fgmotion scenario** (muted background run, steady synthetic turn, 4x): every shown image of 4 game frames saved
  as presented (request "fgshot"). Edge energy (mean |Laplacian|, scene crop) of the generated frames against the game
  frame they precede: detail off 0.91 vs 1.43 (64%: edges pulse soft/sharp at the rendered rate); detail on 1.40 vs
  1.57 (89%).
- **Thin line beside the minimap:** a copy of the minimap's right border about 10 px beside it, and a bar after the
  clock, in all three generated frames (docs/img/minimap-line-before.png; left generated, right real). Around the HUD
  the real frame is reprojected to the generated frame's moment; the "does that land on the HUD" test read one pixel of
  the UI layer, so the border's soft edge came along. Now 5x5: gone (minimap-line-after.png).
- **GPU address fault** (game exits) with the transparency step and detail both on, at the first denoised frame: run
  bisected (reactive mask off: clean; frame generation's transparency step off: clean); the steps sampled at positions
  made from non-finite motion vectors (sky). Both steps skip non-finite motion vectors now: clean with everything on.

## Correction: the game's MetalFX sharpening does reach the image (2026-10-11)

- The flicker scenario's "CAS has no effect" captured the upscaler's output, before the game's post-processing, where
  that sharpening runs. Measured on the presented image instead (4x frame generation's drawables, scenario "sharp",
  same frozen view): edge energy 1.51 at MetalFX_Sharpness 0 against 1.70 at 0.5 (+13%), while the upscaler's output
  is the same (3.36 / 3.35). So the game sharpens the Apple denoiser's output by its menu setting; the player saw halos
  over a soft image ("too much sharpening", "denoiser too blurry").
- Player settings now: MetalFX Sharpness 0 (game menu), output 3456x2160 instead of 2992x1870 (which the display then
  stretched to its 3456 pixels: blur on top of the upscale), ultra_scale 2.25 (1536x960, about the render cost of
  2992x1870 at 2.0). The plugin's own sharpening (ModMenu slider) stays 0; raise it a little for a crisper image.

## 4x judder in turns (2026-10-11)

- Player: "turn frames warp is severely unstable". The play timeline (in world, 4x): a frame every 48 ms, but its four
  images reached the display 3.7 ms apart (median; p90 6.9 ms), then the picture held for about 37 ms. The pacer
  presented images 2-4 with presentDrawable:afterMinimumDuration: (one refresh after the previous image), which is not
  honored with the game's VSync off (its layer's displaySyncEnabled is NO).
- Now each image after the first is presented at an absolute time, evenly over the frame interval (smoothed interval /
  (k + 1), at least one refresh): presentDrawable:atTime:. Needs a visible display to verify (log_timeline).
- log_timeline is in seconds now (60): counted in frames, it ran every few seconds in menus (300+ fps).
