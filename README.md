# MetalFX Denoiser

A RED4ext plugin for the native macOS build of Cyberpunk 2077 (2.3.1, Apple silicon) that aims to replace the game's
ray-tracing denoiser with Apple MetalFX.

**Status: research prototype. It does not change rendering yet.** On macOS the NRD CPU entry points never run; the
denoiser executes as Metal compute pipelines (see `docs/PIPELINE_TRACE_FINDINGS.md`). The plugin currently loads,
creates a MetalFX context, and can optionally log the compute pipelines the game binds. See `docs/STATUS.md`.

## Quickstart

Requirements: macOS 13+, Apple silicon, CMake 3.20+, Xcode command line tools, RED4ext for macOS installed in the game
folder, and `vendor/RED4ext.SDK` pointing at the RED4ext.SDK checkout (a symlink to `../../RED4ext.SDK` works).

```bash
cmake -S . -B build && cmake --build build -j8   # build only
scripts/install.sh                               # build + install into the game's red4ext/plugins
```

`install.sh` uses the default Steam path; set `GAME_PATH` to override. Start the game with RED4ext's
`launch_red4ext.sh` and read `red4ext/logs/` for `[MetalFXDenoiser]` lines.

To log the game's compute pipeline states, set this in `red4ext/plugins/MetalFXDenoiser/config.toml`:

```toml
[debug]
trace_metal_compute = true
```

## Layout

| Path | Purpose |
|------|---------|
| `src/plugin/main.cpp` | RED4ext entry point |
| `src/plugin/MetalTrace.mm` | Objective-C swizzle of the compute encoder's `setComputePipelineState:` |
| `src/plugin/BufferInterceptor.cpp` | Texture extraction helpers for the replacement path |
| `src/plugin/Config.cpp` | `config.toml` parsing |
| `framework/` | `MetalFXDenoiserCore.dylib`: MetalFX temporal scaler wrapper, scaler pool, buffer converter |
| `docs/` | Status, research findings, buffer layout notes |

## License

MIT, see `LICENSE`.
