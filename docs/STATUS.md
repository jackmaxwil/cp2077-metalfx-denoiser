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

What decides whether the swap pays in FPS: the GPU time of the NRD passes. Unknown until step 1 below.

## Next steps

1. **NRD cost:** skip the named NRD dispatches (tracer option) and measure the frame-time difference in RT Ultra and
   path tracing. That is the most the swap can save (the image is noisy while skipped; it is a measurement).
2. **MetalFX baseline:** rtbench with MetalFX selected, on an idle Mac, several timing windows per spot.
3. **Inputs:** map the G-buffer targets (normals, albedo, roughness) and the pre-denoise lighting textures (descriptor
   heap decoding, or one GPU capture read in Xcode).
4. **Prototype:** create `MTLFXTemporalDenoisedScaler` where the game creates its MetalFX scaler, feed it the mapped
   textures, skip NRD; compare against step 2 (GPU time, flicker, screenshots).
5. **Settings in parallel:** test an ini override of the hidden settings (`CONFIG_VARS.md`: path tracing `RayNumber`,
   `BounceNumber`, the Apple denoiser masks) and measure each with rtbench.
