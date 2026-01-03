#!/bin/bash
# MetalFX Denoiser Launcher
# Launches Cyberpunk 2077 with MetalFX hooks enabled

GAME_PATH="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
GAME_BIN="$GAME_PATH/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
PLUGIN_DIR="$GAME_PATH/red4ext/plugins/MetalFXDenoiser"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== MetalFX Denoiser Launcher ==="
echo ""

# Check if game exists
if [ ! -f "$GAME_BIN" ]; then
    echo "ERROR: Game not found at $GAME_BIN"
    exit 1
fi

# Check if plugin is installed
if [ ! -f "$PLUGIN_DIR/MetalFXDenoiser.dylib" ]; then
    echo "WARNING: MetalFXDenoiser.dylib not installed"
    echo "Installing from build directory..."
    
    BUILD_DIR="$SCRIPT_DIR/../build"
    if [ -f "$BUILD_DIR/libMetalFXDenoiser.dylib" ]; then
        mkdir -p "$PLUGIN_DIR"
        cp "$BUILD_DIR/libMetalFXDenoiser.dylib" "$PLUGIN_DIR/MetalFXDenoiser.dylib"
        cp "$BUILD_DIR/libMetalFXDenoiserCore.dylib" "$PLUGIN_DIR/"
        echo "Installed MetalFXDenoiser plugin"
    else
        echo "ERROR: Build artifacts not found. Run 'make' first."
        exit 1
    fi
fi

# Copy config if not exists
if [ ! -f "$PLUGIN_DIR/config.toml" ]; then
    cp "$SCRIPT_DIR/../config/config.toml.template" "$PLUGIN_DIR/config.toml" 2>/dev/null || true
fi

# Check for Frida
if ! command -v frida &> /dev/null; then
    echo "WARNING: Frida not installed. Install with: pip3 install frida-tools"
    echo "Launching without Frida hooks (plugin-only mode)..."
    echo ""
    
    # Launch via RED4ext launcher if available
    RED4EXT_LAUNCHER="$GAME_PATH/red4ext_launcher.sh"
    if [ -f "$RED4EXT_LAUNCHER" ]; then
        exec "$RED4EXT_LAUNCHER"
    else
        echo "ERROR: RED4ext launcher not found"
        exit 1
    fi
fi

echo "Frida detected. Launching with hooks..."
echo ""

# Launch game with Frida
# Option 1: Spawn with script
echo "Starting Cyberpunk 2077 with MetalFX hooks..."
frida -l "$SCRIPT_DIR/metalfx_hooks.js" -f "$GAME_BIN" --no-pause &
FRIDA_PID=$!

echo "Frida PID: $FRIDA_PID"
echo "Press Ctrl+C to stop"

# Wait for Frida to finish
wait $FRIDA_PID
