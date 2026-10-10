#pragma once

// The game's mouse input and the input-to-display latency meter (Input.mm). The game takes mouse events off the AppKit
// event queue on its main thread (-[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:], hooked here) about
// 10 ms before it presents the frame they went into.
namespace Input {

// Swizzles the event pump (on the main thread).
void Start();

// The newest mouse event the game took before a present call: its event time (the OS's timestamp of the movement),
// when the game dequeued it, and the present call; host times (CACurrentMediaTime), event 0 when the game took no mouse
// movement since the previous present call.
struct FrameInput {
    double event = 0, read = 0, present = 0;
};

// Caps the game's frame rate by waiting right before it reads input for a frame (0 = off). Use instead of the game's
// MaximumFPS, not with it.
void SetFrameLimit(float fps);

// At the game's present call (render thread): what the game read for this frame, kept as the current frame's input.
void BeginFrame();
// The current frame's input (BeginFrame), for the presenter that shows the frame.
FrameInput Current();

} // namespace Input

#ifdef __OBJC__
#include <objc/objc.h>
namespace Input {
// Latency of the frame shown by drawable (a game frame, not a generated one): input to display, logged per path
// ("off": the game's own present, "2x", "4x") every 120 frames with mouse movement, with its three parts.
void Track(id drawable, const FrameInput& in, const char* path);
} // namespace Input
#endif
