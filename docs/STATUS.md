# MetalFX Denoiser: Status

> **Last updated:** 2026-10-07
> **Target:** Cyberpunk 2077 macOS 2.3.1, Apple silicon, RED4ext for macOS
> **Status:** research prototype, no rendering changes

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
less than NRD. Its input must be the noisy lighting composited as if NRD had passed it through: NRD's debug split
screen (`Editor/Denoising/NRD/DebugSplitScreen`) does that, being tested next.

## Next steps

1. **Done: frame cost by part** (passcost): ray generation 41%, NRD 9%, refits under 5%, MetalFX 1% in RT Ultra.
1b. **Done: runtime access to the engine's settings** (`CONFIG_VARS.md`): 190 ray tracing variables verified in
   RED4ext's address DB, read and written by this plugin; live changes reach the renderer (half resolution tracing
   toggles change RT Ultra by 1.2-1.5 ms). Next: the path tracing cost knobs (SHaRC bounces and downscale, multilayer
   resolution scale, ReSTIR GI samples), with image comparisons, not only timings.
2. **MetalFX baseline:** rtbench with MetalFX selected, on an idle Mac, several timing windows per spot.
3. **Inputs:** map the G-buffer targets (normals, albedo, roughness) and the pre-denoise lighting textures (descriptor
   heap decoding, or one GPU capture read in Xcode).
4. **Prototype:** create `MTLFXTemporalDenoisedScaler` where the game creates its MetalFX scaler, feed it the mapped
   textures, skip NRD; compare against step 2 (GPU time, flicker, screenshots).
5. **Settings:** once the registry is reachable (1b), measure the hidden settings (half resolution tracing, path
   tracing rays and bounces, the Apple denoiser masks) with passcost and rtbench.
