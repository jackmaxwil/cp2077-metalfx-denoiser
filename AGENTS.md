# MetalFX Denoiser: agent guide

RED4ext plugin for the native macOS Cyberpunk 2077 2.3.1 (Apple silicon). Goal: replace the ray-tracing denoiser with
Apple MetalFX. Status and next steps: `docs/STATUS.md`. Research: `docs/PIPELINE_TRACE_FINDINGS.md`.

## Rules

1. **Native only.** Hooks run in process: RED4ext's plugin hooking API (`aSdk->hooking->Attach`) for C++ functions,
   Objective-C method swizzling (`method_setImplementation`) for Metal. No external instrumentation or injectors.
2. **Fail closed.** Game addresses come only from RED4ext's address DB entries marked verified. No NRD entry point is
   verified, so no C++ hook is attached. Never hardcode or guess offsets.
3. **Never launch the game or Steam from tooling.** No osascript. In-game tests go through RED4ext's `tools/cp-run`.
4. **Commits:** one logical change per commit on `main`, plain messages, no attribution lines, never force-push.

## Layout

- `MetalFXDenoiser.dylib` (plugin, C++/ObjC++): `src/plugin/main.cpp`, `MetalTrace.mm`, `BufferInterceptor.cpp`,
  `Config.cpp`, `Logger.cpp`.
- `MetalFXDenoiserCore.dylib` (installed in the plugin's `bin/`): `framework/MetalBridge.h` (C API),
  `MetalFXDenoiser.mm`, `TemporalScalerPool.mm`, `BufferConverter.mm`.

## Checks before handing back

- `cmake -S . -B build && cmake --build build -j8` builds with no errors.
- `python3 ../RED4ext.SDK/scripts/plugin_requirements.py build/MetalFXDenoiser.dylib` reports 0 unverified.
