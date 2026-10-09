#pragma once

#include <string>

namespace ConfigVars {

// "<group>/<name>" logs the value; "<group>/<name>=<value>" sets it. Returns a JSON line with the result (or the
// reason nothing was done). See ConfigVars.cpp for the checks.
std::string Apply(const std::string& request);

// The render scale of upscaler quality 4 (MetalFX "Ultra Performance", reached with MFX/OverrideEnable=1 and
// MFX/Quality=4): the fourth entry of the engine's scale table (address DB "Upscaler/ScaleTable", verified by
// RED4ext.SDK scripts/upscaler_scale_table.py), 3.0 in the game. Accepts 2.0 to 3.0; writes only when the table in
// memory reads [1.5, 1.7, 2.0, x] with x in that range. Returns false and says why when nothing was written.
bool SetUltraScale(float scale, std::string& why);

} // namespace ConfigVars
