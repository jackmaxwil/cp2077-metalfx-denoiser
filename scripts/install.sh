#!/bin/bash
# MetalFX Denoiser Installation Script

GAME_PATH="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
PLUGIN_DIR="$GAME_PATH/red4ext/plugins/MetalFXDenoiser"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../build"

echo "=== MetalFX Denoiser Installer ==="
echo ""

# Check if game exists
if [ ! -d "$GAME_PATH" ]; then
    echo "ERROR: Cyberpunk 2077 not found at:"
    echo "  $GAME_PATH"
    echo ""
    echo "Please install the game via Steam first."
    exit 1
fi

# Check if RED4ext is installed
if [ ! -d "$GAME_PATH/red4ext" ]; then
    echo "WARNING: RED4ext not found."
    echo "MetalFX Denoiser requires RED4ext to load."
    echo "Install RED4ext first from: https://github.com/memaxo/RED4ext"
    echo ""
fi

# Check build artifacts
if [ ! -f "$BUILD_DIR/libMetalFXDenoiser.dylib" ]; then
    echo "Build artifacts not found. Building..."
    cd "$SCRIPT_DIR/.."
    mkdir -p build
    cd build
    cmake ..
    make -j8
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Build failed"
        exit 1
    fi
    echo ""
fi

# Create plugin directory
echo "Installing to: $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"

# Copy files
echo "  Copying MetalFXDenoiser.dylib..."
cp "$BUILD_DIR/libMetalFXDenoiser.dylib" "$PLUGIN_DIR/MetalFXDenoiser.dylib"

echo "  Copying MetalFXDenoiserCore.dylib..."
cp "$BUILD_DIR/libMetalFXDenoiserCore.dylib" "$PLUGIN_DIR/"

echo "  Copying config.toml..."
cp "$SCRIPT_DIR/../config/config.toml.template" "$PLUGIN_DIR/config.toml"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Files installed:"
ls -la "$PLUGIN_DIR"
echo ""
echo "To use MetalFX Denoiser:"
echo "  1. Launch game via RED4ext launcher"
echo "  2. Enable Ray Tracing in graphics settings"
echo "  3. Check red4ext/logs for MetalFX messages"
echo ""
echo "For Frida hooks (advanced):"
echo "  ./scripts/launch_with_metalfx.sh"
