# MetalFX Denoiser

A RED4ext plugin for the native macOS build of Cyberpunk 2077 (2.3.1, Apple silicon) that replaces the game's ray
tracing denoiser (NRD RELAX) and its MetalFX upscaler with Apple's MetalFX temporal denoised scaler (macOS 26).

- Works with ray traced lighting (Ultra, Psycho) and path tracing, with the game's Resolution Scaling set to MetalFX.
  Raster frames and other upscalers are left alone.
- Path tracing: 0.2-0.7 ms faster per frame than the game's NRD at the same MetalFX preset; recovers from motion at
  least as well. RT Ultra: about 0.5 ms slower than NRD, cleaner after motion. Numbers: `docs/PIPELINE_TRACE_FINDINGS.md`.
- Tip: with the denoiser on, MetalFX Performance looks close to the game's Quality in path tracing and is about 25%
  faster.

## Use it

Install (below), start the game with RED4ext's `launch_red4ext.sh`, load a save, and switch it in ModMenu (`` ` `` or
F10) > MetalFX Denoiser > "Apple MetalFX denoiser". ModMenu remembers the choice. Without ModMenu, set it in
`red4ext/plugins/MetalFXDenoiser/config.toml`:

```toml
[metalfx]
enabled = true
```

"Debug: noisy lighting" shows the lighting with no denoiser at all (comparisons only).

### Path tracing at native resolution

Starting point at 3456x2160 (M4 Max): path tracing, Resolution Scaling MetalFX, and in `config.toml`

```toml
[metalfx]
enabled = true
ultra_performance = true  # render below the output and let MetalFX upscale
ultra_scale = 2.5         # 3.0 is fastest (about 28 ms per rendered frame), 2.5 sharper (about 38 ms)
texture_lod_bias = -0.32  # matches the scale: log2(2 / ultra_scale); -0.585 for 3.0
sharpness = 0.4           # lower it if thin far detail (wires) looks blocky
frame_generation = true   # about twice the displayed frames, for about 5 ms per rendered frame
```

ModMenu > MetalFX Denoiser switches the denoiser, Ultra Performance, frame generation, the render scale and the
sharpening while playing; the texture LOD bias applies from the next game start.

## Build and install

Requirements: macOS 26 for the denoiser (the plugin loads on 14+ and leaves rendering alone), Apple silicon, CMake
3.20+, Xcode command line tools, RED4ext for macOS installed in the game folder, and `vendor/RED4ext.SDK` pointing at the
RED4ext.SDK checkout (a symlink to `../../RED4ext.SDK` works).

```bash
cmake -S . -B build && cmake --build build -j8   # build only
scripts/install.sh                               # build + install into the game's red4ext/plugins
```

`install.sh` uses the default Steam path; set `GAME_PATH` to override. It replaces `config.toml` with the template.
Logs: `red4ext/logs/`, `[MetalFXDenoiser]` lines.

Research tools (Metal tracer, frame dumps, benchmarks): `[debug] trace_metal_compute = true` or `METALFX_TRACE=1`; see
`docs/STATUS.md` and RED4ext's `tools/rtbench` (scenarios `rtbench`, `passcost`, `denoise`, `motion`, `denoiser-menu`,
`dump`, `cvarbatch`).

## Layout

| Path | Purpose |
|------|---------|
| `src/plugin/main.cpp` | RED4ext entry point |
| `src/plugin/Denoise.mm` | The denoiser: RELAX pass-through, guide textures, camera from NRD's constants, the denoised scaler |
| `src/plugin/MetalTrace.mm` | Metal method hooks the denoiser runs in; the research tracer (traces, timings, dumps) |
| `src/plugin/ConfigVars.cpp` | The engine's config variables by name (verified addresses only) |
| `src/plugin/modmenu_api.h` | Copy of ModMenu's C API header |
| `tests/` | `trace_selftest` (tracer and pass-through), `denoiser_bench` (denoised scaler cost) |
| `src/plugin/Config.cpp` | `config.toml` parsing |
| `framework/` | `MetalFXDenoiserCore.dylib`: MetalFX temporal scaler wrapper, scaler pool, buffer converter |
| `docs/` | Status, research findings, buffer layout notes |

## License

MIT, see `LICENSE`.
