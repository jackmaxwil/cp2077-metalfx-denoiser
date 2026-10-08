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

## Next steps

1. Steadier measurements: several timing windows per spot; idle Mac.
2. Decode each dispatch's top-level argument buffer (root signature to descriptor heap) to name every texture a pass
   reads and writes; map the G-buffer targets (normals, base color, roughness) and NRD's inputs and outputs.
3. Finish the static shader cache's name table (reliable pass names).
4. Find which upscaler option selects MetalFX on macOS (the labels do not match what the game creates).
5. Test the hidden settings (`CONFIG_VARS.md`) through an ini override; measure each with rtbench.
6. Replace NRD plus the MetalFX temporal scaler with `MTLFXTemporalDenoisedScaler` (macOS 26) and compare with
   rtbench.
