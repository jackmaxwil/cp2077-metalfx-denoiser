/**
 * MetalFX Denoiser - Frida Hook Script
 * 
 * This script hooks NRD denoiser functions and redirects them to MetalFX.
 * Load via Frida Gadget or frida-inject.
 * 
 * Usage:
 *   frida -l metalfx_hooks.js -f Cyberpunk2077
 */

'use strict';

// Configuration
const CONFIG = {
    enabled: true,
    logCalls: true,
    shadowsEnabled: true,
    diffuseEnabled: true,
    specularEnabled: true,
    rtxdiEnabled: true
};

// NRD Function Addresses (Game v2.21)
const NRD_ADDRESSES = {
    REBLUR_Diffuse: 0xF5A408,
    REBLUR_DiffuseSpecular: 0xF6AFA0,
    SIGMA_Shadow: 0xF7901C,
    NrdInputs: 0xFEF864,
    RTXDI_Denoising: 0x16B9578,
    FilterOutput: 0xFEDE44
};

// Get base address
const baseAddr = Module.findBaseAddress('Cyberpunk2077');
if (!baseAddr) {
    console.error('[MetalFX] ERROR: Could not find Cyberpunk2077 module');
} else {
    console.log('[MetalFX] Base address: ' + baseAddr);
}

// Statistics
const stats = {
    shadowCalls: 0,
    diffuseCalls: 0,
    specularCalls: 0,
    rtxdiCalls: 0,
    totalFrames: 0
};

// MetalFX context (will be set by native plugin)
let metalFXContext = null;
let nativePlugin = null;
let nativeInitialized = false;

/**
 * Initialize connection to native MetalFX plugin
 */
function initNativePlugin() {
    try {
        // Find MetalFXDenoiser.dylib (try multiple names)
        let metalfxModule = Process.findModuleByName('MetalFXDenoiser.dylib');
        if (!metalfxModule) {
            metalfxModule = Process.findModuleByName('libMetalFXDenoiser.dylib');
        }
        if (!metalfxModule) {
            console.log('[MetalFX] Native plugin not loaded yet');
            console.log('[MetalFX] Will operate in logging-only mode');
            return false;
        }
        
        console.log('[MetalFX] Found native plugin at: ' + metalfxModule.base);
        
        // Get exported functions
        nativePlugin = {
            // Hook callbacks (called from Frida to invoke MetalFX)
            hookREBLUR_Diffuse: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_HookREBLUR_Diffuse') || ptr(0),
                'bool', ['pointer', 'pointer', 'pointer']
            ),
            hookREBLUR_DiffuseSpecular: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_HookREBLUR_DiffuseSpecular') || ptr(0),
                'bool', ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']
            ),
            hookSIGMA_Shadow: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_HookSIGMA_Shadow') || ptr(0),
                'bool', ['pointer', 'pointer', 'pointer']
            ),
            onNrdInputsConfigured: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_OnNrdInputsConfigured') || ptr(0),
                'void', ['pointer']
            ),
            setJitter: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_SetJitter') || ptr(0),
                'void', ['float', 'float']
            ),
            signalCameraCut: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_SignalCameraCut') || ptr(0),
                'void', []
            ),
            isReplacementActive: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_IsReplacementActive') || ptr(0),
                'bool', []
            ),
            getPerformanceMetrics: new NativeFunction(
                metalfxModule.findExportByName('MetalFX_GetPerformanceMetrics') || ptr(0),
                'void', ['pointer', 'pointer', 'pointer']
            )
        };
        
        // Check if native side is ready
        if (nativePlugin.isReplacementActive && !nativePlugin.isReplacementActive.isNull()) {
            nativeInitialized = nativePlugin.isReplacementActive();
            console.log('[MetalFX] Native replacement active: ' + nativeInitialized);
        }
        
        console.log('[MetalFX] Native plugin connected successfully');
        return true;
    } catch (e) {
        console.error('[MetalFX] Failed to init native plugin: ' + e);
        return false;
    }
}

/**
 * Hook REBLUR_Diffuse temporal accumulation
 */
function hookREBLUR_Diffuse() {
    const addr = baseAddr.add(NRD_ADDRESSES.REBLUR_Diffuse);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            if (!CONFIG.enabled || !CONFIG.diffuseEnabled) return;
            
            this.denoiserState = args[0];
            this.inputBuffer = args[1];
            this.outputBuffer = args[2];
            this.useMetalFX = false;
            
            // Try to use MetalFX if native plugin is ready
            if (nativeInitialized && nativePlugin.hookREBLUR_Diffuse && !nativePlugin.hookREBLUR_Diffuse.isNull()) {
                try {
                    this.useMetalFX = nativePlugin.hookREBLUR_Diffuse(
                        this.denoiserState,
                        this.inputBuffer,
                        this.outputBuffer
                    );
                } catch (e) {
                    console.error('[MetalFX] Native hook failed: ' + e);
                }
            }
            
            if (CONFIG.logCalls) {
                console.log('[MetalFX] REBLUR_Diffuse called (MetalFX: ' + this.useMetalFX + ')');
            }
            
            stats.diffuseCalls++;
        },
        onLeave: function(retval) {
            if (CONFIG.logCalls && stats.diffuseCalls % 60 === 0) {
                console.log('[MetalFX] Diffuse calls: ' + stats.diffuseCalls);
            }
        }
    });
    
    console.log('[MetalFX] Hooked REBLUR_Diffuse @ ' + addr);
}

/**
 * Hook REBLUR_DiffuseSpecular temporal accumulation
 */
function hookREBLUR_DiffuseSpecular() {
    const addr = baseAddr.add(NRD_ADDRESSES.REBLUR_DiffuseSpecular);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            if (!CONFIG.enabled || (!CONFIG.diffuseEnabled && !CONFIG.specularEnabled)) return;
            
            this.denoiserState = args[0];
            this.diffuseInput = args[1];
            this.specularInput = args[2];
            this.diffuseOutput = args[3];
            this.specularOutput = args[4];
            
            if (CONFIG.logCalls) {
                console.log('[MetalFX] REBLUR_DiffuseSpecular called');
            }
            
            stats.specularCalls++;
        },
        onLeave: function(retval) {
            if (CONFIG.logCalls && stats.specularCalls % 60 === 0) {
                console.log('[MetalFX] DiffuseSpecular calls: ' + stats.specularCalls);
            }
        }
    });
    
    console.log('[MetalFX] Hooked REBLUR_DiffuseSpecular @ ' + addr);
}

/**
 * Hook SIGMA Shadow filter
 */
function hookSIGMA_Shadow() {
    const addr = baseAddr.add(NRD_ADDRESSES.SIGMA_Shadow);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            if (!CONFIG.enabled || !CONFIG.shadowsEnabled) return;
            
            this.filterState = args[0];
            this.shadowInput = args[1];
            this.shadowOutput = args[2];
            this.useMetalFX = false;
            
            // Try to use MetalFX if native plugin is ready
            if (nativeInitialized && nativePlugin.hookSIGMA_Shadow && !nativePlugin.hookSIGMA_Shadow.isNull()) {
                try {
                    this.useMetalFX = nativePlugin.hookSIGMA_Shadow(
                        this.filterState,
                        this.shadowInput,
                        this.shadowOutput
                    );
                } catch (e) {
                    console.error('[MetalFX] Native shadow hook failed: ' + e);
                }
            }
            
            if (CONFIG.logCalls) {
                console.log('[MetalFX] SIGMA_Shadow called (MetalFX: ' + this.useMetalFX + ')');
            }
            
            stats.shadowCalls++;
        },
        onLeave: function(retval) {
            if (CONFIG.logCalls && stats.shadowCalls % 60 === 0) {
                console.log('[MetalFX] Shadow calls: ' + stats.shadowCalls);
            }
        }
    });
    
    console.log('[MetalFX] Hooked SIGMA_Shadow @ ' + addr);
}

/**
 * Hook NrdInputs configuration
 */
function hookNrdInputs() {
    const addr = baseAddr.add(NRD_ADDRESSES.NrdInputs);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            this.config = args[0];
            
            // Notify native plugin of configuration
            if (nativeInitialized && nativePlugin.onNrdInputsConfigured && !nativePlugin.onNrdInputsConfigured.isNull()) {
                try {
                    nativePlugin.onNrdInputsConfigured(this.config);
                } catch (e) {
                    // Ignore
                }
            }
            
            // Log configuration structure for reverse engineering
            if (CONFIG.logCalls) {
                console.log('[MetalFX] NrdInputs configuration:');
                console.log('  Config ptr: ' + this.config);
                
                // Try to dump some bytes
                if (this.config && !this.config.isNull()) {
                    try {
                        const data = this.config.readByteArray(64);
                        console.log('  First 64 bytes: ' + hexdump(data, { header: false }));
                    } catch (e) {
                        console.log('  Could not read config data');
                    }
                }
            }
        }
    });
    
    console.log('[MetalFX] Hooked NrdInputs @ ' + addr);
}

/**
 * Hook RTXDI denoising enable
 */
function hookRTXDI_Denoising() {
    const addr = baseAddr.add(NRD_ADDRESSES.RTXDI_Denoising);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            if (!CONFIG.enabled || !CONFIG.rtxdiEnabled) return;
            
            if (CONFIG.logCalls) {
                console.log('[MetalFX] RTXDI_Denoising called');
            }
            
            stats.rtxdiCalls++;
        }
    });
    
    console.log('[MetalFX] Hooked RTXDI_Denoising @ ' + addr);
}

/**
 * Hook FilterOutput render node
 */
function hookFilterOutput() {
    const addr = baseAddr.add(NRD_ADDRESSES.FilterOutput);
    
    Interceptor.attach(addr, {
        onEnter: function(args) {
            // This is called for filter output - good place to intercept final result
            this.renderNode = args[0];
            
            stats.totalFrames++;
            
            if (CONFIG.logCalls && stats.totalFrames % 300 === 0) {
                console.log('[MetalFX] Frame ' + stats.totalFrames + ' stats:');
                console.log('  Shadow: ' + stats.shadowCalls);
                console.log('  Diffuse: ' + stats.diffuseCalls);
                console.log('  Specular: ' + stats.specularCalls);
                console.log('  RTXDI: ' + stats.rtxdiCalls);
            }
        }
    });
    
    console.log('[MetalFX] Hooked FilterOutput @ ' + addr);
}

/**
 * Utility: Hex dump helper
 */
function hexdump(data, options) {
    const bytes = new Uint8Array(data);
    let result = '';
    for (let i = 0; i < bytes.length; i++) {
        result += bytes[i].toString(16).padStart(2, '0') + ' ';
        if ((i + 1) % 16 === 0) result += '\n';
    }
    return result;
}

/**
 * RPC exports for external control
 */
rpc.exports = {
    setEnabled: function(enabled) {
        CONFIG.enabled = enabled;
        console.log('[MetalFX] ' + (enabled ? 'Enabled' : 'Disabled'));
    },
    
    setShadowsEnabled: function(enabled) {
        CONFIG.shadowsEnabled = enabled;
    },
    
    setDiffuseEnabled: function(enabled) {
        CONFIG.diffuseEnabled = enabled;
    },
    
    setSpecularEnabled: function(enabled) {
        CONFIG.specularEnabled = enabled;
    },
    
    setLogging: function(enabled) {
        CONFIG.logCalls = enabled;
    },
    
    getStats: function() {
        return stats;
    },
    
    resetStats: function() {
        stats.shadowCalls = 0;
        stats.diffuseCalls = 0;
        stats.specularCalls = 0;
        stats.rtxdiCalls = 0;
        stats.totalFrames = 0;
    }
};

/**
 * Main initialization
 */
function main() {
    console.log('===========================================');
    console.log('   MetalFX Denoiser Hooks v1.0.0');
    console.log('   Cyberpunk 2077 macOS');
    console.log('===========================================');
    
    if (!baseAddr) {
        console.error('[MetalFX] Cannot proceed without base address');
        return;
    }
    
    // Try to connect to native plugin
    initNativePlugin();
    
    // Install hooks
    console.log('[MetalFX] Installing NRD hooks...');
    
    try {
        hookREBLUR_Diffuse();
        hookREBLUR_DiffuseSpecular();
        hookSIGMA_Shadow();
        hookNrdInputs();
        hookRTXDI_Denoising();
        hookFilterOutput();
        
        console.log('[MetalFX] All hooks installed successfully');
        console.log('[MetalFX] Ready - enable RT to see denoiser activity');
    } catch (e) {
        console.error('[MetalFX] Hook installation failed: ' + e);
    }
}

// Run main
main();
