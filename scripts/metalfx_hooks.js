/**
 * MetalFX Denoiser - Minimal Frida Hook Script (Release)
 * 
 * This is the production version for hooking NRD denoiser functions.
 * For debugging/analysis, use metalfx_hooks.debug.js instead.
 * 
 * Usage:
 *   frida -l metalfx_hooks.min.js -f Cyberpunk2077
 * 
 * RPC Control:
 *   rpc.exports.setEnabled(true/false)      - Enable/disable all hooks
 *   rpc.exports.setReplaceEnabled(true)     - Enable MetalFX replacement
 *   rpc.exports.getStats()                  - Get call statistics
 *   rpc.exports.getNativePerf()             - Get performance metrics
 */

'use strict';

// Configuration - minimal defaults for production
const CONFIG = {
    enabled: true,
    logCalls: false,              // Disabled in release for performance
    replaceEnabled: false,        // Must be explicitly enabled
    skipOriginalWhenUsed: true,   // Skip NRD when MetalFX succeeds
    shadowsEnabled: true,
    diffuseEnabled: true,
    specularEnabled: true
};

// NRD Function Addresses (Game v2.21)
// These must match AddressResolverOverride.hpp
const NRD_ADDRESSES = {
    REBLUR_Diffuse: 0xF5A408,
    REBLUR_DiffuseSpecular: 0xF6AFA0,
    SIGMA_Shadow: 0xF7901C,
    NrdInputs: 0xFEF864
};

function findCyberpunkBase() {
    try {
        if (typeof Module !== 'undefined' && Module && typeof Module.findBaseAddress === 'function') {
            const b = Module.findBaseAddress('Cyberpunk2077');
            if (b) return b;
        }
    } catch (e) {}

    try {
        const mods = Process.enumerateModules();
        for (const m of mods) {
            if (m.name === 'Cyberpunk2077') return m.base;
            if (m.path && (m.path.endsWith('/Cyberpunk2077') || m.path.endsWith('Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077'))) {
                return m.base;
            }
        }
        if (mods.length > 0) return mods[0].base;
    } catch (e) {}

    return null;
}

const baseAddr = findCyberpunkBase();
if (!baseAddr) {
    console.error('[MetalFX] ERROR: Could not find Cyberpunk2077 module');
} else {
    console.log('[MetalFX] Base address: ' + baseAddr);
}

// Minimal statistics for production
const stats = {
    shadowCalls: 0,
    diffuseCalls: 0,
    specularCalls: 0,
    totalFrames: 0
};

let nativePlugin = null;
let nativeInitialized = false;

// Current frame resources
let currentResources = {
    motion: ptr(0),
    depth: ptr(0),
    cmd: ptr(0),
    jitterX: 0.0,
    jitterY: 0.0,
    reset: false
};

function getExportedFunction(module, name, retType, argTypes) {
    const p = module.findExportByName(name);
    if (!p || p.isNull()) return null;
    return new NativeFunction(p, retType, argTypes);
}

function initNativePlugin() {
    try {
        let metalfxModule = Process.findModuleByName('MetalFXDenoiser.dylib');
        if (!metalfxModule) {
            metalfxModule = Process.findModuleByName('libMetalFXDenoiser.dylib');
        }
        if (!metalfxModule) {
            console.log('[MetalFX] Native plugin not loaded - hooks in logging mode');
            return false;
        }
        
        console.log('[MetalFX] Found native plugin');

        nativePlugin = {
            hookREBLUR_Diffuse: getExportedFunction(metalfxModule, 'MetalFX_HookREBLUR_Diffuse', 'bool', ['pointer', 'pointer', 'pointer']),
            hookREBLUR_DiffuseSpecular: getExportedFunction(metalfxModule, 'MetalFX_HookREBLUR_DiffuseSpecular', 'bool', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']),
            hookSIGMA_Shadow: getExportedFunction(metalfxModule, 'MetalFX_HookSIGMA_Shadow', 'bool', ['pointer', 'pointer', 'pointer']),
            onNrdInputsConfigured: getExportedFunction(metalfxModule, 'MetalFX_OnNrdInputsConfigured', 'void', ['pointer']),
            setJitter: getExportedFunction(metalfxModule, 'MetalFX_SetJitter', 'void', ['float', 'float']),
            signalCameraCut: getExportedFunction(metalfxModule, 'MetalFX_SignalCameraCut', 'void', []),
            isReplacementActive: getExportedFunction(metalfxModule, 'MetalFX_IsReplacementActive', 'bool', []),
            getPerformanceMetrics: getExportedFunction(metalfxModule, 'MetalFX_GetPerformanceMetrics', 'void', ['pointer', 'pointer', 'pointer']),
            setCurrentResources: getExportedFunction(metalfxModule, 'MetalFX_SetCurrentResources', 'void', ['pointer', 'pointer', 'pointer', 'float', 'float', 'bool']),
            setCurrentFeatureTextures: getExportedFunction(metalfxModule, 'MetalFX_SetCurrentFeatureTextures', 'void', ['int', 'pointer', 'pointer']),
            setMotionVectorMode: getExportedFunction(metalfxModule, 'MetalFX_PluginSetMotionVectorMode', 'void', ['int', 'bool'])
        };

        if (nativePlugin.isReplacementActive) {
            try {
                nativeInitialized = nativePlugin.isReplacementActive();
                console.log('[MetalFX] Native replacement active: ' + nativeInitialized);
            } catch (e) {
                nativeInitialized = false;
            }
        }
        
        console.log('[MetalFX] Native plugin connected');
        return true;
    } catch (e) {
        console.error('[MetalFX] Failed to init native plugin: ' + e);
        return false;
    }
}

// Core hook implementations - minimal overhead
function hookREBLUR_Diffuse() {
    const addr = baseAddr.add(NRD_ADDRESSES.REBLUR_Diffuse);
    
    if (!CONFIG.replaceEnabled) {
        Interceptor.attach(addr, {
            onEnter: function(args) {
                if (!CONFIG.enabled || !CONFIG.diffuseEnabled) return;
                stats.diffuseCalls++;
                // Auto-probe for command buffer from denoiser state
                probeForCommandBuffer(args[0]);
            }
        });
        console.log('[MetalFX] Attached REBLUR_Diffuse @ ' + addr);
        return;
    }

    var original = null;
    const originalPtr = Interceptor.replace(addr, new NativeCallback(function(x0, x1, x2) {
        stats.diffuseCalls++;
        if (!original) return;

        if (!CONFIG.enabled || !CONFIG.diffuseEnabled || !nativeInitialized) {
            original(x0, x1, x2);
            return;
        }

        try {
            if (nativePlugin.setCurrentResources) {
                nativePlugin.setCurrentResources(
                    currentResources.motion,
                    currentResources.depth,
                    currentResources.cmd,
                    currentResources.jitterX,
                    currentResources.jitterY,
                    currentResources.reset
                );
                currentResources.reset = false;
            }
            if (nativePlugin.setCurrentFeatureTextures) {
                nativePlugin.setCurrentFeatureTextures(3, x1, x2);
            }
        } catch (e) {}

        let used = false;
        try {
            used = nativePlugin.hookREBLUR_Diffuse(x0, x1, x2);
        } catch (e) {
            used = false;
        }

        if (!used || !CONFIG.skipOriginalWhenUsed) {
            original(x0, x1, x2);
        }
    }, 'void', ['pointer', 'pointer', 'pointer']));

    original = new NativeFunction(originalPtr, 'void', ['pointer', 'pointer', 'pointer']);
    console.log('[MetalFX] Replaced REBLUR_Diffuse @ ' + addr);
}

function hookREBLUR_DiffuseSpecular() {
    const addr = baseAddr.add(NRD_ADDRESSES.REBLUR_DiffuseSpecular);
    
    if (!CONFIG.replaceEnabled) {
        Interceptor.attach(addr, {
            onEnter: function(args) {
                if (!CONFIG.enabled) return;
                stats.specularCalls++;
            }
        });
        console.log('[MetalFX] Attached REBLUR_DiffuseSpecular @ ' + addr);
        return;
    }

    var original = null;
    const originalPtr = Interceptor.replace(addr, new NativeCallback(function(a0, a1, a2, a3, a4) {
        stats.specularCalls++;
        if (!original) return;
        
        if (!CONFIG.enabled || !nativeInitialized) {
            original(a0, a1, a2, a3, a4);
            return;
        }

        try {
            if (nativePlugin.setCurrentFeatureTextures) {
                nativePlugin.setCurrentFeatureTextures(3, a1, a3);
                nativePlugin.setCurrentFeatureTextures(4, a2, a4);
            }
            if (nativePlugin.setCurrentResources) {
                nativePlugin.setCurrentResources(
                    currentResources.motion,
                    currentResources.depth,
                    currentResources.cmd,
                    currentResources.jitterX,
                    currentResources.jitterY,
                    currentResources.reset
                );
                currentResources.reset = false;
            }
        } catch (e) {}

        let used = false;
        try {
            used = nativePlugin.hookREBLUR_DiffuseSpecular(a0, a1, a2, a3, a4);
        } catch (e) {
            used = false;
        }

        if (!used || !CONFIG.skipOriginalWhenUsed) {
            original(a0, a1, a2, a3, a4);
        }
    }, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']));

    original = new NativeFunction(originalPtr, 'void', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
    console.log('[MetalFX] Replaced REBLUR_DiffuseSpecular @ ' + addr);
}

function hookSIGMA_Shadow() {
    const addr = baseAddr.add(NRD_ADDRESSES.SIGMA_Shadow);
    
    if (!CONFIG.replaceEnabled) {
        Interceptor.attach(addr, {
            onEnter: function(args) {
                if (!CONFIG.enabled || !CONFIG.shadowsEnabled) return;
                stats.shadowCalls++;
            }
        });
        console.log('[MetalFX] Attached SIGMA_Shadow @ ' + addr);
        return;
    }

    var original = null;
    const originalPtr = Interceptor.replace(addr, new NativeCallback(function(x0, x1, x2) {
        stats.shadowCalls++;
        if (!original) return;

        if (!CONFIG.enabled || !CONFIG.shadowsEnabled || !nativeInitialized) {
            original(x0, x1, x2);
            return;
        }

        try {
            if (nativePlugin.setCurrentResources) {
                nativePlugin.setCurrentResources(
                    currentResources.motion,
                    currentResources.depth,
                    currentResources.cmd,
                    currentResources.jitterX,
                    currentResources.jitterY,
                    currentResources.reset
                );
                currentResources.reset = false;
            }
            if (nativePlugin.setCurrentFeatureTextures) {
                nativePlugin.setCurrentFeatureTextures(0, x1, x2);
            }
        } catch (e) {}

        let used = false;
        try {
            used = nativePlugin.hookSIGMA_Shadow(x0, x1, x2);
        } catch (e) {
            used = false;
        }

        if (!used || !CONFIG.skipOriginalWhenUsed) {
            original(x0, x1, x2);
        }
    }, 'void', ['pointer', 'pointer', 'pointer']));

    original = new NativeFunction(originalPtr, 'void', ['pointer', 'pointer', 'pointer']);
    console.log('[MetalFX] Replaced SIGMA_Shadow @ ' + addr);
}

function hookNrdInputs() {
    const addr = baseAddr.add(NRD_ADDRESSES.NrdInputs);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            if (nativeInitialized && nativePlugin && nativePlugin.onNrdInputsConfigured) {
                try {
                    nativePlugin.onNrdInputsConfigured(args[0]);
                } catch (e) {}
            }

            // Auto-capture jitter from NrdInputs struct
            // Heuristic: scan for plausible float pairs (jitter is typically -0.5..0.5)
            try {
                const configPtr = args[0];
                if (!configPtr.isNull()) {
                    // Common NRD struct layouts place jitter at offset 0x10-0x20
                    for (let off = 0x10; off <= 0x30; off += 4) {
                        const fval = configPtr.add(off).readFloat();
                        if (Math.abs(fval) > 0.0001 && Math.abs(fval) < 1.0) {
                            const fval2 = configPtr.add(off + 4).readFloat();
                            if (Math.abs(fval2) > 0.0001 && Math.abs(fval2) < 1.0) {
                                currentResources.jitterX = fval;
                                currentResources.jitterY = fval2;
                                break;
                            }
                        }
                    }
                }
            } catch (e) {}
        }
    });
    
    console.log('[MetalFX] Hooked NrdInputs @ ' + addr);
}

// Auto-capture: extract command buffer from NRD arg[0] (denoiser state)
// NRD denoiser state typically has a command buffer reference at a known offset.
// This hook runs once at startup to probe arg structure, then caches the offset.
let cmdBufferOffset = -1;
let probeCount = 0;
const MAX_PROBES = 10;

function probeForCommandBuffer(statePtr) {
    if (probeCount >= MAX_PROBES || cmdBufferOffset >= 0) return;
    probeCount++;

    // Scan offsets 0x00..0x80 for an Objective-C pointer that looks like MTLCommandBuffer
    for (let off = 0; off <= 0x80; off += 8) {
        try {
            const candidate = statePtr.add(off).readPointer();
            if (candidate.isNull()) continue;
            // Check if it responds to MTLCommandBuffer protocol (heuristic: check isa pointer)
            const isa = candidate.readPointer();
            if (isa.isNull()) continue;
            // If isa is in a valid range and looks like an Obj-C class, this might be our cmd buffer
            const isaVal = isa.toInt32 ? isa.toInt32() : 0;
            if (isaVal !== 0) {
                currentResources.cmd = candidate;
                cmdBufferOffset = off;
                if (CONFIG.logCalls) {
                    console.log('[MetalFX] Auto-captured cmd buffer at state+0x' + off.toString(16));
                }
                return;
            }
        } catch (e) {}
    }
}

function probeForTextures(argPtr, featureId) {
    // NRD buffer args typically wrap an MTLTexture.
    // Try common offsets: +0x00 (direct pointer), +0x10, +0x30
    try {
        if (!argPtr.isNull()) {
            // Pass raw pointer to native plugin - it has SafeRead-based extraction
            if (nativePlugin && nativePlugin.setCurrentFeatureTextures) {
                nativePlugin.setCurrentFeatureTextures(featureId, argPtr, ptr(0));
            }
        }
    } catch (e) {}
}

// RPC exports for runtime control
rpc.exports = {
    setEnabled: function(enabled) {
        CONFIG.enabled = enabled;
        console.log('[MetalFX] ' + (enabled ? 'Enabled' : 'Disabled'));
    },
    
    setReplaceEnabled: function(enabled) {
        CONFIG.replaceEnabled = enabled;
        console.log('[MetalFX] Replace mode: ' + (enabled ? 'ON' : 'OFF'));
    },

    setSkipOriginalWhenUsed: function(enabled) {
        CONFIG.skipOriginalWhenUsed = enabled ? true : false;
    },
    
    signalCameraCut: function() {
        currentResources.reset = true;
        try {
            if (nativeInitialized && nativePlugin && nativePlugin.signalCameraCut) {
                nativePlugin.signalCameraCut();
            }
        } catch (e) {}
    },
    
    setResources: function(motionPtr, depthPtr, cmdPtr, jitterX, jitterY, reset) {
        try {
            currentResources.motion = ptr(motionPtr);
            currentResources.depth = ptr(depthPtr);
            currentResources.cmd = ptr(cmdPtr);
            currentResources.jitterX = jitterX;
            currentResources.jitterY = jitterY;
            currentResources.reset = reset ? true : false;
        } catch (e) {}
    },

    setMotionVectorMode: function(mode, flipY) {
        try {
            if (nativeInitialized && nativePlugin && nativePlugin.setMotionVectorMode) {
                nativePlugin.setMotionVectorMode(mode | 0, flipY ? true : false);
            }
        } catch (e) {}
    },

    getNativePerf: function() {
        try {
            if (!nativeInitialized || !nativePlugin || !nativePlugin.getPerformanceMetrics) {
                return null;
            }
            const avg = Memory.alloc(8);
            const processed = Memory.alloc(8);
            const fallback = Memory.alloc(8);
            nativePlugin.getPerformanceMetrics(avg, processed, fallback);
            return {
                avgTimeMs: avg.readDouble(),
                framesProcessed: processed.readU64().toNumber(),
                framesFallback: fallback.readU64().toNumber()
            };
        } catch (e) {
            return null;
        }
    },
    
    getStats: function() {
        return stats;
    },
    
    resetStats: function() {
        stats.shadowCalls = 0;
        stats.diffuseCalls = 0;
        stats.specularCalls = 0;
        stats.totalFrames = 0;
    }
};

function main() {
    console.log('===========================================');
    console.log('   MetalFX Denoiser Hooks v1.0.0 (Release)');
    console.log('   Cyberpunk 2077 macOS');
    console.log('===========================================');
    
    if (!baseAddr) {
        console.error('[MetalFX] Cannot proceed without base address');
        return;
    }
    
    initNativePlugin();
    
    console.log('[MetalFX] Installing NRD hooks...');
    
    try {
        hookREBLUR_Diffuse();
        hookREBLUR_DiffuseSpecular();
        hookSIGMA_Shadow();
        hookNrdInputs();
        
        console.log('[MetalFX] Hooks installed successfully');
        console.log('[MetalFX] Run: rpc.exports.setReplaceEnabled(true) to enable MetalFX');
    } catch (e) {
        console.error('[MetalFX] Hook installation failed: ' + e);
    }
}

main();
