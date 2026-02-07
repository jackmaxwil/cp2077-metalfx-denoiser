# MetalFX Denoiser - In-Game Validation Checklist

Use this checklist when testing the mod in-game to verify release mode functionality.

## Pre-Test Setup

### 1. Build Artifacts Ready
- [ ] `MetalFXDenoiser.dylib` (149KB) - built successfully
- [ ] `MetalFXDenoiserCore.dylib` (98KB) - built successfully
- [ ] `metalfx_hooks.js` copied to release (same as min.js)

### 2. Installation Layout
```
~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext/plugins/MetalFXDenoiser/
├── MetalFXDenoiser.dylib              # Main plugin
├── config.toml                        # Optional config
└── bin/
    └── MetalFXDenoiserCore.dylib     # Metal framework
```

### 3. Frida Script Available
- [ ] `scripts/metalfx_hooks.js` is accessible (for runtime hook injection)

## Phase 1: Plugin Load Validation

**Launch game via RED4ext and check logs:**

### Expected Log Sequence
```
[MetalFXDenoiser] Initializing MetalFX Denoiser v1.0.0
[MetalFXDenoiser] Target game version: 2.21
[MetalFXDenoiser] Validating NRD addresses...
[MetalFXDenoiser] Address validation: Required 3/3, Optional 3/3
[MetalFXDenoiser] Address validation passed
[MetalFXDenoiser] MetalFX context created successfully
[MetalFXDenoiser] Frida integration initialized
[MetalFXDenoiser] Hook infrastructure initialized
[MetalFXDenoiser]  NOTE: Runtime hook installation requires Frida integration
[MetalFXDenoiser]  Load: frida -l metalfx_hooks.js -p <pid>
[MetalFXDenoiser] Initialization complete
```

### Checklist
- [ ] Plugin version logged (v1.0.0)
- [ ] Game version logged (2.21)
- [ ] Address validation shows "Required 3/3" (REBLUR_Diffuse, REBLUR_DiffuseSpecular, SIGMA_Shadow)
- [ ] Address validation **PASSED**
- [ ] MetalFX context created successfully
- [ ] No ERROR or FATAL messages

### If Address Validation Fails
If you see:
```
[MetalFXDenoiser] FATAL: Address validation failed
[MetalFXDenoiser] This mod version is incompatible with your game version
```

**Action:** Game version mismatch. Run post-update procedure:
```bash
cd scripts && python3 discover_nrd_addresses.py
# Update offsets in lib/Support/macOS/AddressResolverOverride.hpp
# Rebuild and reinstall
```

## Phase 2: Hook Installation Validation

**Attach Frida hooks:**

```bash
# Get game PID
game_pid=$(pgrep Cyberpunk2077)

# Attach hooks
frida -l scripts/metalfx_hooks.js -p $game_pid
```

### Expected Frida Output
```
===========================================
   MetalFX Denoiser Hooks v1.0.0 (Release)
   Cyberpunk 2077 macOS
===========================================
[MetalFX] Base address: 0x100000000
[MetalFX] Found native plugin
[MetalFX] Native replacement active: true
[MetalFX] Native plugin connected
[MetalFX] Installing NRD hooks...
[MetalFX] Attached REBLUR_Diffuse @ 0x100f5a408
[MetalFX] Attached REBLUR_DiffuseSpecular @ 0x100f6afa0
[MetalFX] Attached SIGMA_Shadow @ 0x100f7901c
[MetalFX] Hooked NrdInputs @ 0x100fef864
[MetalFX] Hooks installed successfully
[MetalFX] Run: rpc.exports.setReplaceEnabled(true) to enable MetalFX
```

### Checklist
- [ ] Base address resolved (0x100000000)
- [ ] Native plugin found and connected
- [ ] Native replacement shows "active: true"
- [ ] All 3 main hooks attached successfully
- [ ] Addresses match expected values (0xF5A408, 0xF6AFA0, 0xF7901C)

## Phase 3: Runtime Validation

**In Frida REPL, enable replacement:**

```javascript
rpc.exports.setReplaceEnabled(true)
```

### Expected Output
```
[MetalFX] Replace mode: ON
```

**Verify hooks are intercepting calls:**

```javascript
rpc.exports.getStats()
```

### Expected Result (after playing for ~30 seconds with RT enabled)
```javascript
{
  shadowCalls: 45,        // Should be > 0
  diffuseCalls: 30,       // Should be > 0  
  specularCalls: 25,      // Should be > 0
  totalFrames: 0          // Not tracked in release mode
}
```

### Checklist
- [ ] `setReplaceEnabled(true)` returns without error
- [ ] After 30s of gameplay with RT on:
  - [ ] `stats.shadowCalls > 0`
  - [ ] `stats.diffuseCalls > 0`
  - [ ] `stats.specularCalls > 0`

## Phase 4: Performance Validation

**Check MetalFX performance metrics:**

```javascript
rpc.exports.getNativePerf()
```

### Expected Result
```javascript
{
  avgTimeMs: 1.2,        // Should be reasonable (< 5ms)
  framesProcessed: 42,   // Should be > 0 and increasing
  framesFallback: 3      // Some fallback is normal
}
```

### Checklist
- [ ] `framesProcessed > 0` and incrementing over time
- [ ] `avgTimeMs` is reasonable (0.5ms - 3ms typical)
- [ ] Some `framesFallback` is OK (scene transitions, no RT)

## Success Criteria

**All phases must pass:**

1. ✅ Plugin loads without address validation errors
2. ✅ Frida hooks attach successfully with correct addresses
3. ✅ Hook call counters increment during gameplay
4. ✅ Performance metrics show frames being processed

**If any phase fails:**
- Check game version matches mod target version (2.21)
- Verify dylibs are in correct directory structure
- Check Console.app for crash logs
- Re-run address discovery if game updated

## Common Issues

### "Native plugin not loaded"
- Dylibs not in correct directory
- RED4ext not loading the plugin
- Check RED4ext logs

### "Address validation failed"
- Game version mismatch
- Run `discover_nrd_addresses.py` and rebuild

### "0 frames processed"
- Replacement not enabled: run `setReplaceEnabled(true)`
- Ray tracing not enabled in game
- Wrong buffer offsets (needs debug analysis)

### High fallback rate
- Normal during scene transitions
- Check that motion vectors are available
- May need debug hooks to analyze buffer structure

## Release Readiness

This mod is **release-ready** when:
- [ ] All 4 validation phases pass
- [ ] No crashes after 30+ minutes of gameplay
- [ ] Performance improvement measurable vs vanilla NRD
- [ ] Clean uninstall (delete dylibs) works without issues
