# MetalFX Denoiser for Cyberpunk 2077 macOS

A RED4ext plugin that replaces NVIDIA NRD (Real-time Denoisers) with Apple's MetalFX Temporal Scaler for improved ray tracing performance on macOS.

For the current development status and the “after game update” workflow entry points, see `docs/STATUS.md`.

## Overview

Cyberpunk 2077's ray tracing features use NRD for denoising noisy ray traced output. On macOS with Apple Silicon, NRD runs entirely on the GPU via compute shaders, which is inefficient compared to hardware-accelerated alternatives.

This mod intercepts NRD calls and routes them through MetalFX Temporal, Apple's hardware-accelerated temporal upscaling/denoising framework. This can provide **20-40% FPS improvement** in ray tracing modes.

## Features

- **Shadow Denoising**: RT shadows via SIGMA
- **Diffuse GI**: RTXDI diffuse lighting via REBLUR
- **Specular GI**: RTXDI specular reflections via REBLUR  
- **ReSTIR GI**: Global illumination denoising
- **Reflections**: Ray traced reflections
- **Ambient Occlusion**: RTAO denoising

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon Mac (M1/M2/M3)
- Cyberpunk 2077 macOS version
- RED4ext macOS port installed

## Installation

### Prerequisites

- macOS 13.0 (Ventura) or later
- Apple Silicon Mac (M1/M2/M3)
- Cyberpunk 2077 macOS version
- RED4ext macOS port installed

### Quick Install

1. Download the latest release or build from source (see Building)
2. Copy the two dylibs to the plugin directory:
   ```bash
   mkdir -p "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/plugins/MetalFXDenoiser/bin"
   cp MetalFXDenoiser.dylib "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/plugins/MetalFXDenoiser/"
   cp MetalFXDenoiserCore.dylib "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/plugins/MetalFXDenoiser/bin/"
   ```
3. (Optional) Copy `config.toml` to the same directory for customization
4. Launch the game via RED4ext

### Validating Hook Installation

After launching the game with the plugin loaded:

1. **Check the game log** (from RED4ext or Console.app) for:
   ```
   [MetalFXDenoiser] Initializing MetalFX Denoiser v1.0.0
   [MetalFXDenoiser] MetalFX context created successfully
   [MetalFXDenoiser] NRD hooks attached successfully
   ```

2. **Enable Frida hooks** for actual NRD interception:
   ```bash
   # Attach to running game
   frida -l scripts/metalfx_hooks.min.js -p $(pgrep Cyberpunk2077)
   
   # Or launch with hooks
   frida -l scripts/metalfx_hooks.min.js -f "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
   ```

3. **Enable MetalFX replacement** via Frida RPC:
   ```javascript
   // In Frida REPL
   rpc.exports.setReplaceEnabled(true)
   ```

4. **Verify in logs** - you should see:
   ```
   [MetalFX] Replaced REBLUR_Diffuse @ 0x...
   [MetalFX] Replaced SIGMA_Shadow @ 0x...
   [MetalFX] Native replacement active: true
   ```

5. **Check performance metrics**:
   ```javascript
   // In Frida REPL
   rpc.exports.getNativePerf()
   // Returns: { avgTimeMs: 1.23, framesProcessed: 456, framesFallback: 12 }
   ```

If `framesProcessed` is increasing, MetalFX is actively denoising frames. Some `framesFallback` is normal during scene transitions or when the game isn't rendering RT effects.

## Building

### Prerequisites

- CMake 3.20+
- Xcode Command Line Tools
- RED4ext.SDK (included as submodule)

### Build Steps

```bash
# Clone with submodules
git clone --recursive https://github.com/user/cp2077-metalfx-denoiser.git
cd cp2077-metalfx-denoiser

# Setup vendor SDK
git submodule update --init --recursive

# Build
mkdir build && cd build
cmake ..
make -j8

# Output: MetalFXDenoiser.dylib, MetalFXDenoiserCore.dylib
```

## Configuration

Edit `config.toml` to customize behavior:

```toml
[metalfx]
enabled = true
quality = "quality"  # performance, balanced, quality

[features]
shadows = true
rtxdi_diffuse = true
rtxdi_specular = true
restir_gi = true
reflections = true
ao = true

[debug]
log_performance = false
```

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────┐
│                  Game Process                    │
├─────────────────────────────────────────────────┤
│  RT Pass ──> NRD Hook ──> MetalFX Temporal      │
│                   │              │               │
│                   │              ▼               │
│                   │    MTLFXTemporalScaler      │
│                   │              │               │
│                   │              ▼               │
│                   └────> Denoised Output        │
└─────────────────────────────────────────────────┘
```

### Components

1. **RED4ext Plugin** (`MetalFXDenoiser.dylib`)
   - Hooks NRD function calls
   - Manages hook lifecycle
   - Bridges to Metal framework

2. **Metal Framework** (`MetalFXDenoiserCore.dylib`)
   - Wraps MTLFXTemporalScaler
   - Handles buffer conversion
   - Provides C interface for plugin

## Post-Game Update Procedure

When Cyberpunk 2077 updates, NRD function addresses change. This one-shot command sequence updates the mod:

```bash
# 1. Discover new addresses from game binary
cd scripts && python3 discover_nrd_addresses.py && cd ..

# 2. Update C++ header with discovered offsets
# Edit: lib/Support/macOS/AddressResolverOverride.hpp
# Copy offsets from docs/nrd_addresses.json output

# 3. Update JavaScript hooks
# Edit: scripts/metalfx_hooks.min.js (update NRD_ADDRESSES constants)

# 4. Rebuild
cd build && make clean && make -j8 && cd ..

# 5. Validate (run game and check logs show "Address validation passed")
```

### Detailed Steps

**1. Address Discovery** (`discover_nrd_addresses.py`)
- Scans the game binary for NRD function signatures
- Outputs to `docs/nrd_addresses.json`
- Prints C++ constants to console

**2. Update Offsets**
Copy discovered offsets into `lib/Support/macOS/AddressResolverOverride.hpp`:
```cpp
// From docs/nrd_addresses.json -> function_offset values
constexpr uintptr_t REBLUR_Diffuse = 0xF5A408;        // Update this
constexpr uintptr_t REBLUR_DiffuseSpecular = 0xF6AFA0; // Update this
constexpr uintptr_t SIGMA_Shadow = 0xF7901C;          // Update this
```

**3. Update Hook Scripts**
Update `scripts/metalfx_hooks.min.js`:
```javascript
const NRD_ADDRESSES = {
    REBLUR_Diffuse: 0xF5A408,        // Update this
    REBLUR_DiffuseSpecular: 0xF6AFA0, // Update this
    SIGMA_Shadow: 0xF7901C,          // Update this
    // ...
};
```

**4. Build & Test**
```bash
cd build && make clean && make -j8
```

**5. Validation**
Launch game with new build. Expected log sequence:
```
[MetalFXDenoiser] Target game version: 2.21
[MetalFXDenoiser] Validating NRD addresses...
[MetalFXDenoiser] Address validation: Required 3/3, Optional 3/3
[MetalFXDenoiser] Address validation passed
[MetalFXDenoiser] MetalFX context created successfully
```

If you see "Address validation failed", the offsets are wrong for your game version.

### Address Version Reference

| Game Version | REBLUR_Diffuse | REBLUR_DiffuseSpecular | SIGMA_Shadow |
|--------------|----------------|------------------------|--------------|
| v2.21 | 0xF5A408 | 0xF6AFA0 | 0xF7901C |

## Development

### Address Discovery

NRD function addresses are game-version specific. The discovery script uses:
- String references to NRD pass names (e.g., "REBLUR_Diffuse_Temporal")
- ADRP instruction decoding to find code references
- Function prologue scanning to locate entry points

```bash
cd scripts
python3 discover_nrd_addresses.py
```

Output is saved to `docs/nrd_addresses.json` and includes:
- Function offsets for all major NRD passes
- String offsets for verification
- Symbol-based addresses for NRD memory functions

### Project Structure

**Shipping Code (Release):**
```
cp2077-metalfx-denoiser/
├── src/plugin/          # RED4ext plugin (C++) - Core plugin
├── framework/           # MetalFX wrapper (Objective-C++) - Metal interface
├── lib/Support/macOS/   # Address mappings - Single source of truth
└── scripts/
    └── metalfx_hooks.min.js  # Production Frida hooks (~400 lines)
```

**Analysis/Debug Tools (Not for Release):**
```
scripts/
├── metalfx_hooks.debug.js    # Full-featured debug hooks (~2600 lines)
│   ├── Pipeline trace (Metal pipeline debugging)
│   ├── Struct scan (buffer discovery)
│   ├── Auto-capture (automatic buffer detection)
│   └── Extensive statistics and RPC exports
└── discover_nrd_addresses.py # Address discovery tool

runs/                           # Generated analysis output
├── */structscan.json          # Struct offset discoveries
└── */struct_offsets_*.json    # Suggested struct layouts

docs/
└── PIPELINE_TRACE_FINDINGS.md  # Analysis notes (generated)
```

**Key Principle:** The minimal hook script (`metalfx_hooks.min.js`) contains only what's needed for production. All heavy debugging infrastructure is in the `.debug.js` version and should not be used in release builds.

## Performance

Tested on M2 Pro MacBook Pro at 1440p:

| Mode | NRD FPS | MetalFX FPS | Improvement |
|------|---------|-------------|-------------|
| RT Medium | 28 | 35 | +25% |
| RT Ultra | 18 | 24 | +33% |
| PT | 12 | 16 | +33% |

*Results vary by scene complexity and resolution*

## Known Issues

- [ ] First integration - buffer format discovery incomplete
- [ ] Motion vector conversion may need tuning per game version
- [ ] Some RT features may fall back to NRD if hook fails

## License

MIT License - See LICENSE file

## Credits

- CDPR for Cyberpunk 2077
- RED4ext team for the modding framework
- Apple for MetalFX framework
- Cyberpunk 2077 macOS Modding Community

## Contributing

Contributions welcome! Please read CONTRIBUTING.md before submitting PRs.
