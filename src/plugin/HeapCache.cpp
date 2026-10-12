#include "HeapCache.hpp"

#include "Fnv1a.hpp"
#include "Logger.hpp"

#include <RED4ext/RED4ext.hpp>

#include <algorithm>
#include <atomic>
#include <string>
#include <cstdio>
#include <cstring>

namespace {

// The heap's entry points (2.3.1; RED4ext.SDK scripts/medium_heap.py). The allocation result is {pointer, usable size}
// in x0/x1; free takes a {pointer, size} pair and writes the freed block's usable size into its second word.
struct Block {
    void* ptr;
    uint64_t size;
};
using AllocFn = Block (*)(uint8_t* heap, uint64_t size, uint64_t align);
using AllocDefaultFn = Block (*)(uint8_t* heap, uint64_t size);
using FreeFn = void (*)(uint8_t* heap, Block* block);
using InitFn = void (*)(uint8_t* heap, void* region);
using ReleaseFn = void (*)(uint8_t* heap);
AllocFn o_alloc = nullptr;
AllocDefaultFn o_allocDefault = nullptr;
FreeFn o_free = nullptr;
InitFn o_init = nullptr;
ReleaseFn o_release = nullptr;

std::atomic<bool> g_on{false};
std::atomic<uint32_t> g_epoch{1}; // bumped by any heap's Init or Release: every thread's cache is dropped
std::atomic<uint64_t> g_hits{0}, g_misses{0}, g_cachedFrees{0}, g_passFrees{0}, g_resets{0};

constexpr int kMinLog = 9, kMaxLog = 16, kClasses = kMaxLog - kMinLog + 1; // 512 B .. 64 KB (usable)
constexpr int kPerClass = 8, kHeaps = 4;
constexpr uint64_t kBytesPerHeap = 256 * 1024;

struct HeapCacheT {
    uint8_t* heap = nullptr;
    uint64_t bytes = 0;
    uint8_t n[kClasses] = {};
    void* blocks[kClasses][kPerClass];
};
struct ThreadCache {
    uint32_t epoch = 0;
    HeapCacheT heaps[kHeaps];
    uint32_t hits = 0, misses = 0, cached = 0, passed = 0; // flushed to the globals every 1024 operations
};
thread_local ThreadCache t_cache;

// A TLSF block's usable size, from its header word at ptr - 8 (low 32 bits, two flag bits).
uint64_t Usable(void* ptr)
{
    uint64_t word;
    std::memcpy(&word, static_cast<uint8_t*>(ptr) - 8, sizeof(word));
    return (static_cast<uint32_t>(word) - 0x10u) & ~3u;
}

int FloorLog2(uint64_t v)
{
    return 63 - __builtin_clzll(v);
}

void Flush(ThreadCache& t)
{
    if (t.hits + t.misses + t.cached + t.passed >= 1024) {
        g_hits.fetch_add(t.hits, std::memory_order_relaxed);
        g_misses.fetch_add(t.misses, std::memory_order_relaxed);
        g_cachedFrees.fetch_add(t.cached, std::memory_order_relaxed);
        g_passFrees.fetch_add(t.passed, std::memory_order_relaxed);
        t.hits = t.misses = t.cached = t.passed = 0;
    }
}

// This thread's cache of heap (made on first use), or nullptr when it already tracks kHeaps others.
HeapCacheT* Of(uint8_t* heap)
{
    ThreadCache& t = t_cache;
    const uint32_t epoch = g_epoch.load(std::memory_order_acquire);
    if (t.epoch != epoch) { // a heap was (re)initialized or released: its blocks may be gone; forget them all
        for (HeapCacheT& h : t.heaps) {
            h = HeapCacheT{};
        }
        t.epoch = epoch;
    }
    for (HeapCacheT& h : t.heaps) {
        if (h.heap == heap) {
            return &h;
        }
    }
    for (HeapCacheT& h : t.heaps) {
        if (!h.heap) {
            h.heap = heap;
            return &h;
        }
    }
    return nullptr;
}

bool Open(uint8_t* heap)
{
    return heap[0x81] == 0; // the heap's own "no allocations" flag: leave it to the heap
}

Block Take(uint8_t* heap, uint64_t size)
{
    if (size == 0 || size > (1ull << kMaxLog) || !Open(heap)) {
        return {nullptr, 0};
    }
    HeapCacheT* h = Of(heap);
    if (!h) {
        return {nullptr, 0};
    }
    int c = size <= (1ull << kMinLog) ? kMinLog : FloorLog2(size - 1) + 1; // every block in class c has 2^c or more
    c -= kMinLog;
    if (c >= kClasses || h->n[c] == 0) {
        ++t_cache.misses;
        Flush(t_cache);
        return {nullptr, 0};
    }
    void* p = h->blocks[c][--h->n[c]];
    const uint64_t usable = Usable(p);
    h->bytes -= usable;
    ++t_cache.hits;
    Flush(t_cache);
    return {p, usable};
}

Block H_alloc(uint8_t* heap, uint64_t size, uint64_t align)
{
    if (g_on.load(std::memory_order_relaxed) && static_cast<uint32_t>(align) <= 16) { // TLSF blocks are 16-aligned
        if (Block b = Take(heap, size); b.ptr) {
            return b;
        }
    }
    return o_alloc(heap, size, align);
}

Block H_allocDefault(uint8_t* heap, uint64_t size)
{
    if (g_on.load(std::memory_order_relaxed)) {
        if (Block b = Take(heap, size); b.ptr) {
            return b;
        }
    }
    return o_allocDefault(heap, size);
}

void H_free(uint8_t* heap, Block* block)
{
    if (g_on.load(std::memory_order_relaxed) && block && block->ptr) {
        const uint64_t usable = Usable(block->ptr);
        if (usable >= (1ull << kMinLog) && usable < (2ull << kMaxLog)) {
            if (HeapCacheT* h = Of(heap); h && h->bytes + usable <= kBytesPerHeap) {
                const int c = std::min(FloorLog2(usable), kMaxLog) - kMinLog;
                if (h->n[c] < kPerClass) {
                    h->blocks[c][h->n[c]++] = block->ptr;
                    h->bytes += usable;
                    block->size = usable; // as the heap's free reports it
                    ++t_cache.cached;
                    Flush(t_cache);
                    return;
                }
            }
        }
        ++t_cache.passed;
        Flush(t_cache);
    }
    o_free(heap, block);
}

// ponytail: one epoch for all heaps; a reset forgets (leaks) the cached blocks of the other heaps too, at most 256 KB
// per heap and thread. Per-heap epochs if resets turn out frequent (logged with the stats).
void H_init(uint8_t* heap, void* region)
{
    g_epoch.fetch_add(1, std::memory_order_acq_rel);
    g_resets.fetch_add(1, std::memory_order_relaxed);
    o_init(heap, region);
}

void H_release(uint8_t* heap)
{
    g_epoch.fetch_add(1, std::memory_order_acq_rel);
    g_resets.fetch_add(1, std::memory_order_relaxed);
    o_release(heap);
}

} // namespace

namespace HeapCache {

void Attach(void* handle, const void* opaque)
{
    const auto* sdk = static_cast<const RED4ext::v1::Sdk*>(opaque);
    struct Hook {
        const char* name;
        void* detour;
        void** original;
    } hooks[] = {
        {"Memory/MediumHeap/Init", reinterpret_cast<void*>(&H_init), reinterpret_cast<void**>(&o_init)},
        {"Memory/MediumHeap/Release", reinterpret_cast<void*>(&H_release), reinterpret_cast<void**>(&o_release)},
        {"Memory/MediumHeap/Free", reinterpret_cast<void*>(&H_free), reinterpret_cast<void**>(&o_free)},
        {"Memory/MediumHeap/Alloc", reinterpret_cast<void*>(&H_alloc), reinterpret_cast<void**>(&o_alloc)},
        {"Memory/MediumHeap/AllocDefault", reinterpret_cast<void*>(&H_allocDefault),
         reinterpret_cast<void**>(&o_allocDefault)},
    };
    if (!sdk || !sdk->hooking) {
        return;
    }
    uintptr_t addresses[5];
    for (int i = 0; i < 5; ++i) { // all or none: a cache with only some entry points hooked would lose blocks
        addresses[i] = RED4ext::UniversalRelocBase::Resolve(Fnv1a32(hooks[i].name));
        if (!addresses[i]) {
            Logger::Warn(std::string("Heap cache: ") + hooks[i].name + " is not a verified entry in the address DB; off");
            return;
        }
    }
    for (int i = 0; i < 5; ++i) {
        if (!sdk->hooking->Attach(static_cast<RED4ext::v1::PluginHandle>(handle), reinterpret_cast<void*>(addresses[i]),
                                  hooks[i].detour, hooks[i].original)) {
            Logger::Error(std::string("Heap cache: hooking ") + hooks[i].name + " failed; off");
            g_on.store(false);
            return; // the hooks attached so far pass straight through while off
        }
    }
    Logger::Info("Heap cache: medium heap entry points hooked");
}

void SetEnabled(bool on)
{
    if (on && !o_alloc) {
        return;
    }
    g_on.store(on);
    Logger::Info(std::string("Heap cache: ") + (on ? "on" : "off"));
}

void LogStats()
{
    char buf[200];
    std::snprintf(buf, sizeof(buf), "Heap cache: %llu hits, %llu misses, %llu frees cached, %llu frees passed, %llu heap "
                  "resets (counts flushed per thread every 1024)", (unsigned long long)g_hits.exchange(0),
                  (unsigned long long)g_misses.exchange(0), (unsigned long long)g_cachedFrees.exchange(0),
                  (unsigned long long)g_passFrees.exchange(0), (unsigned long long)g_resets.exchange(0));
    Logger::Info(buf);
}

} // namespace HeapCache
