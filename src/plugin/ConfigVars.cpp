// Engine config variables (CConfigVar), read and written at runtime by name.
//
// Addresses come only from RED4ext's address DB, entries marked verified (RED4ext.SDK scripts/config_var_dump.py,
// docs/CONFIG_VAR_AUDIT.md): "ConfigVar/<group>/<name>" for the object and "ConfigVar/@bool|int|float" for the value
// types' vtables, each hashed with FNV1a32. Before touching a variable the object is checked in memory: its name and
// group pointers (+0x8, +0x10) must point to the expected strings and its vtable must be one of the three types.
// Value: +0x2c (bool: 1 byte; int, float: 4 bytes). Nothing is written when any check fails.

#include "ConfigVars.hpp"
#include "Logger.hpp"

#include <RED4ext/RED4ext.hpp>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include <mach/mach.h>
#include <mach/mach_vm.h>

namespace {

uint32_t Fnv1a32(const std::string& text)
{
    uint32_t h = 0x811C9DC5u;
    for (unsigned char c : text) {
        h = (h ^ c) * 0x01000193u;
    }
    return h;
}

enum class Type { Unknown, Bool, Int, Float };

const char* TypeName(Type t)
{
    switch (t) {
    case Type::Bool: return "bool";
    case Type::Int: return "int";
    case Type::Float: return "float";
    default: return "unknown";
    }
}

struct Var {
    uint8_t* object = nullptr;
    Type type = Type::Unknown;
};

// Resolves and checks one variable; on failure returns false and says why.
bool Lookup(const std::string& path, Var& out, std::string& why)
{
    const auto slash = path.find_last_of('/');
    if (slash == std::string::npos || slash == 0 || slash + 1 == path.size()) {
        why = "expected <group>/<name>";
        return false;
    }
    const std::string group = path.substr(0, slash), name = path.substr(slash + 1);
    const auto address = RED4ext::UniversalRelocBase::Resolve(Fnv1a32("ConfigVar/" + path));
    if (!address) {
        why = "not a verified entry in the address DB";
        return false;
    }
    auto* object = reinterpret_cast<uint8_t*>(address);
    const char* nameAt = *reinterpret_cast<const char* const*>(object + 0x8);
    const char* groupAt = *reinterpret_cast<const char* const*>(object + 0x10);
    if (!nameAt || !groupAt || name != nameAt || group != groupAt) {
        why = "the object's name or group does not match";
        return false;
    }
    const auto vtable = *reinterpret_cast<const uintptr_t*>(object);
    Type type = Type::Unknown;
    for (auto [t, key] : {std::pair{Type::Bool, "bool"}, {Type::Int, "int"}, {Type::Float, "float"}}) {
        const auto expected = RED4ext::UniversalRelocBase::Resolve(Fnv1a32(std::string("ConfigVar/@") + key));
        if (expected && vtable == expected) {
            type = t;
        }
    }
    if (type == Type::Unknown) {
        why = "not a bool, int or float variable (vtable not a verified type)";
        return false;
    }
    out = {object, type};
    return true;
}

std::string ValueString(const Var& v)
{
    switch (v.type) {
    case Type::Bool: return v.object[0x2C] ? "true" : "false";
    case Type::Int: return std::to_string(*reinterpret_cast<const int32_t*>(v.object + 0x2C));
    case Type::Float: return std::to_string(*reinterpret_cast<const float*>(v.object + 0x2C));
    default: return "?";
    }
}

} // namespace

namespace ConfigVars {

std::string Apply(const std::string& request)
{
    const auto eq = request.find('=');
    const std::string path = request.substr(0, eq);
    Var v;
    std::string why;
    if (!Lookup(path, v, why)) {
        const std::string line = "{\"var\":\"" + path + "\",\"error\":\"" + why + "\"}";
        Logger::Warn("Config var " + path + ": " + why);
        return line;
    }
    const std::string before = ValueString(v);
    if (eq != std::string::npos) {
        const std::string text = request.substr(eq + 1);
        switch (v.type) {
        case Type::Bool:
            v.object[0x2C] = (text == "true" || text == "1") ? 1 : 0;
            break;
        case Type::Int: {
            const auto value = static_cast<int32_t>(std::strtoll(text.c_str(), nullptr, 0));
            std::memcpy(v.object + 0x2C, &value, sizeof(value));
            break;
        }
        case Type::Float: {
            const float value = std::strtof(text.c_str(), nullptr);
            std::memcpy(v.object + 0x2C, &value, sizeof(value));
            break;
        }
        default:
            break;
        }
    }
    const std::string after = ValueString(v);
    Logger::Info("Config var " + path + " (" + TypeName(v.type) + "): " + before +
                 (eq != std::string::npos ? " -> " + after : ""));
    return "{\"var\":\"" + path + "\",\"type\":\"" + TypeName(v.type) + "\",\"before\":\"" + before +
           "\",\"after\":\"" + after + "\"}";
}

bool SetUltraScale(float scale, std::string& why)
{
    if (!(scale >= 2.0f && scale <= 3.0f)) {
        why = "scale outside 2.0-3.0";
        return false;
    }
    const auto address = RED4ext::UniversalRelocBase::Resolve(Fnv1a32("Upscaler/ScaleTable"));
    if (!address) {
        why = "Upscaler/ScaleTable is not a verified entry in the address DB";
        return false;
    }
    auto* table = reinterpret_cast<float*>(address);
    if (table[0] != 1.5f || table[1] != 1.7f || table[2] != 2.0f || !(table[3] >= 2.0f && table[3] <= 3.0f)) {
        why = "the table in memory does not read [1.5, 1.7, 2.0, 2..3]";
        return false;
    }
    if (table[3] == scale) {
        return true;
    }
    // __TEXT,__const is read-only: copy-on-write the page, write, and give it back its original protection. The page
    // holds only constants (no code), so no thread executes from it while it is writable.
    const mach_vm_address_t page = address & ~static_cast<uintptr_t>(vm_page_size - 1);
    kern_return_t kr = mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        why = "mach_vm_protect(RW|COPY) failed: " + std::to_string(kr);
        return false;
    }
    const float before = table[3];
    table[3] = scale;
    kr = mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        Logger::Error("Upscaler scale table: restoring R|X failed: " + std::to_string(kr));
    }
    Logger::Info("Upscaler scale table: quality 4 " + std::to_string(before) + " -> " + std::to_string(scale));
    return true;
}

} // namespace ConfigVars
