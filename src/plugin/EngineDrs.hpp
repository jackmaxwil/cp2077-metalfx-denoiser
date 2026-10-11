#pragma once

// The engine's own dynamic resolution (MetalFX "Dynamic" in the game's menu; docs/DRS_RECON.md). Its render targets
// are allocated at the maximum size and each frame renders into a top-left rectangle, and MetalFX is created once with
// content properties, so a size change costs nothing. A hook after DRS::Update (address DB "DRS/Update", verified)
// observes its state and, when SetScale gives one, replaces its size with ours and widens its floor to 3x.
namespace EngineDrs {

// At plugin load. Fails closed: no verified address or an unexpected prologue leaves the engine alone.
// handle and sdk: Main's RED4ext::v1::PluginHandle and const RED4ext::v1::Sdk* (kept opaque so the self-test needs
// no RED4ext headers).
void Attach(void* handle, const void* sdk);

// The engine's dynamic resolution ran in the last frame (the player chose MetalFX "Dynamic").
bool Active();

// The output-to-render scale to render at (1-3; 0 leaves the size to the engine's own controller), and the sharpest
// scale it will use (the allocation is capped there; 0: the player's DRS maximum).
void SetScale(float scale, float sharpest);

} // namespace EngineDrs
