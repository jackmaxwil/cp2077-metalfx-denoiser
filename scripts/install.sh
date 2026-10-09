#!/bin/bash
# Build the MetalFX Denoiser and install it into the game's RED4ext plugins folder.
# Installs red4ext/plugins/MetalFXDenoiser/{MetalFXDenoiser.dylib, bin/MetalFXDenoiserCore.dylib, config.toml}.
set -euo pipefail

GAME_PATH="${GAME_PATH:-$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$GAME_PATH/red4ext" ]]; then
    echo "ERROR: RED4ext not found in: $GAME_PATH" >&2
    echo "Install RED4ext first, or set GAME_PATH." >&2
    exit 1
fi

cmake -S "$ROOT" -B "$ROOT/build"
cmake --build "$ROOT/build" -j8
cmake --install "$ROOT/build" --prefix "$GAME_PATH"

echo "Installed to: $GAME_PATH/red4ext/plugins/MetalFXDenoiser"
echo "Start the game through RED4ext's launch_red4ext.sh; the plugin logs to red4ext/plugins/MetalFXDenoiser/metalfxdenoiser.log."
