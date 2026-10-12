# Input lag profile (2026-10-11)

Setup: path tracing, MetalFX Performance at render scale 2.75 (1257x785 to 3456x2160), the Apple denoiser, the plugin's
frame limit at 29 fps, M4 Max. Background test runs (muted, synthetic mouse input to the game process only), the save's
car scene. Tools added for this: the frame timeline (Timeline.mm, request "timeline", [debug] log_timeline,
scripts/timeline_report.py), the CPU sampler report (scripts/cpu_profile.py over macOS `sample`), Ghidra 12 headless
decompilation of the hottest game functions, and the existing per-encoder GPU profile (scripts/gpu_profile.py).
Raw data (samples, decompilation, per-pass tables) stays in the local run folders (RED4ext/runs/*-lagprof/analysis,
not committed: game code).

## What the player saw (play log, 2026-10-11 19:17-19:22, 4x frame generation)

- Mouse to display 102-147 ms median (p95 up to 187 ms); in menus 16-19 ms.
- The plugin's frame time grew from 33 to 55 ms over the session (18-29 fps); the 29 fps cap held only at the start.

## Where the time goes (timelines, medians in ms; 300 frames each, A/B/A/B)

| Mode | Frame interval | CPU frame | Input read to frame rendered | Present call to GPU done | Game GPU busy | Frame generation GPU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 4x | 37.3 | 12-18 | 75.4 | 60-64 | 46-49 | 11 |
| 4x, low-latency pacing | 38.0 | 19-21 | 60.3 | 55-56 | 46 | 11 |
| 2x | 36.4-37.2 | 11-13 | 47-49 | 34-36 | 37-38 (includes 2x's ~6) | (in the game's) |
| 2x, low-latency pacing | 36.8-37.2 | 11 | 45 | 34 | 37 | |
| Frame generation off | 34.9 | 18-20 | 51-54 | 30 | 31 | 0 |

Plus the display stage (not measurable in a background run; from the player's log and the pacing design): 4x shows the
game's frame after its three generated ones, about 3 refreshes (25 ms) after it is ready; 2x shows it half a frame
after its generated one (about 17 ms); without frame generation about 5-8 ms.

1. **The GPU is oversubscribed with 4x.** Per 37 ms frame the game's work takes 46-49 ms of GPU time and frame
   generation 11 ms more (3 interpolations at 1728x1080, 1.7 ms each; 4 HUD passes at 3456x2160, 0.7 ms each; the frame
   copy, halving, UI snapshots). Frames overlap on the GPU, and each needs about 55-65 ms from its present call to done.
   Without frame generation the game's frame is 31 ms of GPU.
2. **Interpolation holds the game's frame back** (it can only be shown after the images between it and the previous
   one): 3 refreshes at 4x, half a frame at 2x.
3. **Queueing behind the GPU.** The game reads input, runs its CPU frame (12-20 ms), then its frame waits behind the
   previous one on the GPU. Low-latency pacing (Input.mm, like NVIDIA Reflex) starts the frame only when its CPU part
   will end about when the GPU frees up: -15 ms at 4x (75 to 60), -2 to -3 ms at 2x, at the same median frame rate;
   the 95th percentile frame interval rises (4x: 57 to 69 ms).
4. **The CPU is not the limit**: the main thread sleeps 58% of the time in the frame limit.

Estimated mouse-to-display totals: 4x about 100 ms (with pacing about 85), 2x about 62-65, off about 56-60.

## GPU per pass (one frame, per-encoder timestamps; gpu-fg4x.md / gpu-fgoff.md)

Game frame GPU (union of encoders): 38.4 ms with 4x running alongside, 31.4 ms without. Largest parts (without frame
generation): wavefront path tracing 6.0 ms, RTXDI 3.7, the Apple denoiser 1.8 + MetalFX networks 1.1 + 0.5, ReSTIR GI
2.2, raster passes 4.0, volumetrics 1.0, NRD leftovers (RELAX pre-pass) 1.2.

- **A 550 MiB buffer clear every frame:** one blit encoder fills 68 buffers (113, 64, 2x30, 19, 5x15 MiB, ...), 1.4-1.7
  ms of GPU per frame, with and without frame generation. Candidates for a smaller or skipped clear (not yet traced to
  the code that encodes it).
- With 4x the game's own passes take longer (wavefront 6.0 to 7.5 ms): they share the GPU with frame generation.
- Full-size copies add 1.9 ms with 4x (the game frame into the slot, UI snapshots, the real frame to its drawable).

## CPU per function (macOS `sample`, 10 s at 1 ms; cpu-fg4x.md)

16 job workers (redDispatcher1-16) run 22-31% of the time each; across them, per 10 s:

| Function (game, unslid) | What it is (decompiled) | Self time |
| --- | --- | ---: |
| 0x1000020c0 | Byte spinlock, writer side: WFE until 0, then CAS to 0x80 | 6.5 s |
| 0x1009db288 | Job queue push (red::CircularBuffer of job::prv::JobQueueEntry, ticket-ordered MPMC ring, 0x200 bytes per priority): after writing its 40-byte entry it spins (WFE) until earlier producers have published, then wakes workers (0x1009dbb4c, dispatch semaphores) | 5.1 s |
| 0x101c346e4, 0x101c17164, 0x101c34c18 | (render/scene work, not yet named) | 0.4-0.75 s each |
| 0x100002098 | Byte spinlock, reader side | 0.7 s |

- The writer spinlock is the medium-size path of the engine allocator (0x10000f858: sizes over 0x200 bytes or alignment
  over 16 go to the pool's medium allocator at +0xcd80, 0x10000a8a8, behind that lock). The hot callers are
  `DynArray_Realloc` (0x1000286e8, 4.5 s inclusive) from the ray tracing pool (`red::memory::StaticPoolStorage
  <rend::PoolRaytrace>`, 0x101660028) under the per-frame ray tracing scene gathering (0x10108984c, 8.0 s inclusive;
  0x10103aa14, 8.2 s): workers growing dynamic arrays one reallocation at a time and serializing on one lock.
- About 1.2 cores spin in total. That does not lengthen the frame (the CPU waits for the GPU), but on a laptop chip it
  is power the GPU could use. Options: pre-size those arrays (hook DynArray_Realloc for PoolRaytrace to grow
  geometrically), or a per-thread cache in front of the medium allocator.

## The 550 MiB clear (2026-10-11, later)

- Request "fillstat <frames>" groups the game's fillBuffer calls by call site (game offsets of the return address and
  two callers), size, value and buffer label. All 68 large clears come from one function, 0x100fe2e54 (12.5 KB, the
  path tracing frame setup, taken when the ray tracing mode global at 0x108ffd15c is 2), called from 0x1010d6b98 <
  0x100f040f8: about 30 render-graph buffers zeroed (113, 64, 2x30, 19, 5x15, 6x7.5 MiB, ...) and about 40 filled with
  0xFF (3.76 MiB each, likely empty markers), every frame.
- Skipping the zero fills of 8 MiB and more from that function (about 330 MiB; config skip_rt_clears, request
  "rtclears skip|keep"; checked against the binary's UUID and the function's address range, so another game build
  skips nothing): the clear pass (1.5-1.7 ms) is gone from the per-encoder profile (game frame 30.7 -> 28.6 ms in the
  clean pair); same-view captures kept vs skipped 33.3-33.7 dB, as kept vs kept seconds apart (33.7); a 6-minute soak
  with turns and time running logged no GPU errors and showed a normal image.
- **Crash fixed:** with the skip on from launch, the GPU faulted on the first frame (the game exited): a new buffer holds
  garbage and that first clear initializes it (the soak had started with the clears kept). Now each buffer's first
  clear goes through (keyed by object, GPU address and length; reallocations after a render size or scale change are
  new buffers); the same launch-with-skip run was then clean. The player's config keeps skip_rt_clears off until a run
  with render scale changes is clean too.

## Spinlock contention: per-thread heap cache (2026-10-11)

- The medium heap (TLSF, pool +0xcd80) guards Alloc 0x10000a8a8, AllocDefault 0x10000a82c, Free 0x10000aa54, Init
  0x10000a7ac and Release 0x10000a7f4 with one writer spinlock (heap +0x80). RED4ext.SDK scripts/medium_heap.py
  verifies the five (function starts, the lock call at x0 + 0x80, the exact lock routine, each calling its own inner
  TLSF routine, and the TLSF block header the cache reads) and adds them to the address DB.
- HeapCache.cpp hooks them: freed blocks of 512 B to 64 KB go to the freeing thread's cache (8 per power-of-two
  class, 256 KB per heap, 4 heaps per thread); an allocation of up to 64 KB, alignment up to 16, takes one of its class
  without the lock. Cached blocks stay allocated in the heap; any Init or Release drops all caches. Config heap_cache,
  request "heapcache on|off|stats".
- In game (heapab scenario, 4x, turns): 73% of medium allocations from the cache (40668 hits, 14852 misses; 125k
  cached frees), no errors, 1 heap reset. The speed effect is not measured yet: that run was 2-3x slower overall
  (frames 67-100 ms, GPU 66-121 ms per frame, drifting in both halves) with mediaanalysisd (Photos analysis, GPU and
  Neural Engine) at 126% CPU and a stuck unittest process at 99% in the background, and its scene had little lock
  spinning (30 ms per 10 s against 6.5 s in the earlier profile).

## Done

- low_latency (config, request "lowlatency", default on in the template; on in the player's config).
- log_timeline = 1800 in the player's config: a timeline every minute of play, with display times on a visible screen.

## Next

1. Lower the GPU load under 4x: the HUD pass (0.7 ms x 4) can skip most of its work away from the HUD; the frame
   copy into the slot can be dropped; consider 2x for latency (about 35 ms less than 4x).
2. Trace the 550 MiB clear to its encoder and test a smaller or skipped clear.
3. Measure the display stage from the player's next session (log_timeline).
4. CPU: pre-size the ray tracing pool's arrays; measure power and GPU clock with and without.
