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
4d. **Fixed: stutter growing over minutes, a load that never finished.** The buffer registry recorded every buffer
   the game created (metadata plus a lock on buffer creation) and grew without bound while streaming; with the
   denoiser on from boot a load sat on the loading screen for 15 minutes, and a play session started stuttering after
   two. It now records only the large shared heap buffers the camera read needs (2 buffers, 158 MiB, flat over 21,600
   frames of rtbench; loads normally).
4a. **Original plan:** create `MTLFXTemporalDenoisedScaler` where the game creates its MetalFX scaler, feed it the mapped
   textures, skip NRD; compare against step 2 (GPU time, flicker, screenshots).
5. **Settings:** once the registry is reachable (1b), measure the hidden settings (half resolution tracing, path
   tracing rays and bounces, the Apple denoiser masks) with passcost and rtbench.
