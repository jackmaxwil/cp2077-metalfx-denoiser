#pragma once

#include <string>

namespace ConfigVars {

// "<group>/<name>" logs the value; "<group>/<name>=<value>" sets it. Returns a JSON line with the result (or the
// reason nothing was done). See ConfigVars.cpp for the checks.
std::string Apply(const std::string& request);

} // namespace ConfigVars
