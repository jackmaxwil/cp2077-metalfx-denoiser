# MetalFX Denoiser: Status

> **Last updated:** 2026-10-07
> **Target:** Cyberpunk 2077 macOS 2.3.1, Apple silicon, RED4ext for macOS
> **Status:** research prototype, no rendering changes

## What works

- The plugin builds, loads under RED4ext, reads `config.toml`, and creates a MetalFX context.
- `[debug] trace_metal_compute = true` swizzles the driver's compute encoder `setComputePipelineState:` and logs each
  distinct compute pipeline state (pointer, label, thread execution width). Default off.
- `framework/`: MetalFX temporal scaler wrapper, per-feature scaler pool, motion vector / depth conversion.

## What does not

- No denoiser is replaced. Nothing is hooked by default.
- The NRD CPU entry points (REBLUR, SIGMA, NrdInputs) never execute on macOS, and none has a verified entry in the
  RED4ext address DB. The old 2.21 offsets in `docs/ADDRESSES.md` and `docs/nrd_addresses.json` are research notes only.
- `BufferInterceptor`'s wrapper offsets (`docs/BUFFER_LAYOUT.md`) were written for the NRD CPU path and are unvalidated.

## Native next steps

1. **Bindings trace.** Extend `MetalTrace` to the other compute encoder methods (`setTexture:atIndex:`,
   `setBuffer:offset:atIndex:`, `setBytes:length:atIndex:`, `dispatchThreadgroups:...`, `dispatchThreads:...`) and log
   a per-PSO binding signature (slot, size, pixel format), gated by a PSO allowlist.
2. **Identify denoiser PSOs by signature**, not by pointer or label (both change per run). Match the signatures in
   `docs/PIPELINE_TRACE_FINDINGS.md`: full-res RGBA16F color, RG16F motion, R16F depth, R8 mask and half-res
   ping-pong history.
3. **Skip and measure.** Optionally drop the dispatches of one candidate PSO and measure FPS and image change to
   confirm which PSO is the denoiser.
4. **Map slots** to color / motion / depth / history / output for the confirmed PSOs.
5. **Substitute MetalFX** at dispatch time: encode `MetalFX_Denoise` into the game's command buffer for the mapped
   textures, then skip the original dispatch.
6. **Validate** in game through RED4ext's `tools/cp-run`: FPS, GPU time, screenshots at fixed positions.

C++ game functions, if any are needed, are hooked through `aSdk->hooking->Attach` only after their addresses are
verified in the RED4ext address DB.
