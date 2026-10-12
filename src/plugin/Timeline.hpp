#pragma once

#include <cstdint>

// Frame timeline for input lag (request "timeline <frames>", [debug] log_timeline): per game frame, the times along the
// path from the mouse to the display, written as one JSON line per frame to the trace folder's timeline-<n>.jsonl and
// summarized in the log (scripts/timeline_report.py splits latency into its parts). Times are host seconds
// (CACurrentMediaTime). Per frame:
// - mouse: the newest mouse event the game read for it, and when it read it (Input.mm);
// - start: when the frame limit released the frame (Input.mm), present: the game's present call;
// - game GPU: the first start and last end of the game's command buffers committed for the frame, and their busy time;
// - plugin GPU: the same for the plugin's own command buffers (frame generation, its pacer queue);
// - shown: each image shown for the frame (generated quarters and the game's), as the display reported it.
namespace Timeline {

// Records the next frames (0 stops).
void Arm(int frames);
bool Armed();

// The game's present call for frame (MetalTrace's frame counter), with the frame's input times (Input.mm).
void OnGamePresent(uint64_t frame, double event, double read, double start, double presentCall);

// A command buffer about to be committed: its GPU interval is added to frame's game or plugin time.
void OnCommit(void* commandBuffer, uint64_t frame, bool plugin);

// An image the display showed for frame: index 1-3 a generated quarter, 4 the game's frame.
void OnShown(uint64_t frame, int index, double shownAt);

} // namespace Timeline
