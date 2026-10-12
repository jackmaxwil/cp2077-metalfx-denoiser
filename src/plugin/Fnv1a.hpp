#pragma once

#include <cstdint>

// FNV-1a 32-bit: the address DB's hash of an entry's name (RED4ext.SDK scripts).
inline uint32_t Fnv1a32(const char* text)
{
    uint32_t h = 0x811C9DC5u;
    for (; *text; ++text) {
        h = (h ^ static_cast<unsigned char>(*text)) * 0x01000193u;
    }
    return h;
}
