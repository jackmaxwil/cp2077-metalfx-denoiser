#pragma once

#include <cstdint>

// A per-thread cache in front of the engine allocator's medium heaps (TLSF, allocations over 0x200 bytes): every heap
// operation takes one spinlock, and 16 job workers allocating temporary arrays spent about 9% of their time spinning on
// it (docs/LATENCY_PROFILE.md). Freed blocks of 512 B to 64 KB go into the freeing thread's cache (at most 8 per size
// class, 256 KB per heap) and the next allocation of that class on the thread takes one without the lock. Cached blocks
// stay allocated in the heap; a heap's Init or Release (address DB Memory/MediumHeap/*) drops every thread's cache for
// all heaps. Config heap_cache, request "heapcache on|off|stats".
namespace HeapCache {

// Hooks the heap's entry points (verified address DB entries; nothing without them).
void Attach(void* pluginHandle, const void* sdk);
void SetEnabled(bool on);
// Hits, misses and cached frees since the last call, in the log.
void LogStats();

} // namespace HeapCache
