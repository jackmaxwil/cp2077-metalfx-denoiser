// The tracer self-test runs without RED4ext, so engine config variables are not available.
#include "ConfigVars.hpp"

std::string ConfigVars::Apply(const std::string&)
{
    return "{\"error\":\"no RED4ext in the self-test\"}";
}

bool ConfigVars::SetUltraScale(float, std::string& why)
{
    why = "no RED4ext in the self-test";
    return false;
}
