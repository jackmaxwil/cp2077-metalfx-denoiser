# MetalFX Denoiser Development Guide

## Project Status

The MetalFX Denoiser mod is in **early development**. Core infrastructure is complete, but runtime integration requires additional reverse engineering work.

### Completed

- [x] NRD function address discovery (13 addresses found)
- [x] RED4ext plugin skeleton
- [x] MetalFX framework wrapper
- [x] Temporal scaler pool management
- [x] Buffer converter infrastructure
- [x] C bridge interface
- [x] Build system (CMake)

### In Progress

- [ ] Runtime hook installation (needs Frida integration)
- [ ] Game buffer structure reverse engineering
- [ ] Motion vector format validation

### Pending

- [ ] Integration testing with actual game
- [ ] Performance benchmarking
- [ ] Configuration system
- [ ] Quality tuning

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MetalFXDenoiser.dylib                        │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                      NRDHooks.cpp                        │    │
│  │  - Hooks REBLUR_Diffuse, REBLUR_DiffuseSpecular         │    │
│  │  - Redirects to MetalFX                                  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  BufferInterceptor.cpp                   │    │
│  │  - Extracts MTLTexture from game buffers                │    │
│  │  - Provides motion vectors, depth                        │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  MetalFXDenoiserCore.dylib                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   MetalBridge.h (C API)                  │    │
│  │  - MetalFX_CreateContext()                               │    │
│  │  - MetalFX_Denoise()                                     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              MetalFXDenoiser.mm (Obj-C++)                │    │
│  │  - Wraps MTLFXTemporalScaler                             │    │
│  │  - Handles texture configuration                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              TemporalScalerPool.mm                       │    │
│  │  - One scaler per RT feature                             │    │
│  │  - Lazy initialization                                   │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Discovered Addresses (Game v2.21)

| Function | Offset | Purpose |
|----------|--------|---------|
| REBLUR_Diffuse | 0xF5A408 | Diffuse GI denoising |
| REBLUR_DiffuseSpecular | 0xF6AFA0 | Combined denoising |
| SIGMA_Shadow | 0xF7901C | Shadow filtering |
| NrdInputs | 0xFEF864 | NRD configuration |
| NrdAllocate | 0xFA7B7C | Memory allocation |
| NrdReallocate | 0xFA7BCC | Memory reallocation |
| NrdFree | 0xFA7C40 | Memory deallocation |
| FilterOutput | 0xFEDE44 | Render node output |
| RTXDI_Denoising | 0x16B9578 | RTXDI enable/dispatch |

## Next Steps

### 1. Runtime Hook Installation

The hook infrastructure is complete but needs actual hook installation. Options:

**Option A: Frida Integration**
```javascript
// red4ext_hooks.js
Interceptor.attach(Module.findBaseAddress("Cyberpunk2077").add(0xF5A408), {
    onEnter: function(args) {
        // Call MetalFX instead
    }
});
```

**Option B: Direct Binary Patching**
- Patch function prologue to jump to hook
- Requires code cave or trampoline

**Option C: RED4ext Hook API**
- Use existing RED4ext hooking infrastructure
- Need to verify compatibility with these addresses

### 2. Buffer Structure RE

The key unknown is the game's buffer structure. Need to determine:

1. How game represents render targets
2. Where MTLTexture pointer is stored
3. Motion vector format (NDC vs pixels)

**Research approach:**
```bash
# Find buffer creation
strings Cyberpunk2077 | grep -i "createTexture\|allocateBuffer"

# Look for render target names
strings Cyberpunk2077 | grep -i "motionVector\|velocity"
```

### 3. Integration Testing

1. Install plugin alongside RED4ext
2. Launch game with RT enabled
3. Check logs for hook activation
4. Compare visual quality NRD vs MetalFX
5. Measure FPS difference

## Building

```bash
cd /Users/jackmazac/Development/cp2077-metalfx-denoiser
mkdir -p build && cd build
cmake ..
make -j8

# Output
ls -la *.dylib
# libMetalFXDenoiser.dylib      (plugin)
# libMetalFXDenoiserCore.dylib  (framework)
```

## Installation

```bash
GAME_PATH="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
PLUGIN_DIR="$GAME_PATH/red4ext/plugins/MetalFXDenoiser"

mkdir -p "$PLUGIN_DIR"
cp build/libMetalFXDenoiser.dylib "$PLUGIN_DIR/MetalFXDenoiser.dylib"
cp build/libMetalFXDenoiserCore.dylib "$PLUGIN_DIR/"
cp config/config.toml.template "$PLUGIN_DIR/config.toml"
```

## Debugging

### Enable Verbose Logging

Edit `config.toml`:
```toml
[debug]
verbose = true
log_performance = 60  # Log every 60 frames
```

### Check RED4ext Logs

```bash
tail -f "$GAME_PATH/red4ext/logs/red4ext.log"
```

### Metal Frame Capture

Use Xcode Metal debugger to capture frames and inspect:
- Denoiser input textures
- MetalFX temporal scaler output
- GPU timing

## Contributing

1. Fork repository
2. Create feature branch
3. Implement and test
4. Submit PR with description

Key areas needing help:
- Frida hook integration
- Buffer structure reverse engineering  
- Performance optimization
- Testing on different hardware
