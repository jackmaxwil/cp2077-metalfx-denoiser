#pragma once

#include <cstddef>

// The game's mouse input (Input.mm). The game reads the mouse from AppKit events, which its main thread takes off the
// event queue once per game frame (-[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:], hooked here), about
// 10 ms before it presents that frame. Frame warp (Warp.mm) uses these deltas: the game turns the camera by exactly
// 0.873 mrad per count of them (measured, docs/STATUS.md), and the main thread keeps reading them while the GPU still
// works on earlier frames.
namespace Input {

// Swizzles the event pump (main thread).
void Start();

// Cumulative mouse movement as the game took it, at host time t (CACurrentMediaTime), from the last eight seconds;
// false when t is outside the record.
bool GameCounts(double t, double& x, double& y);

// Medians since the last call: the time between the game's pump bursts (its frame time) and how old mouse events were
// when the pump took them.
struct PumpStats {
    double frameMs = 0, eventAgeMs = 0;
    std::size_t bursts = 0;
};
PumpStats TakePumpStats();

// Tests: mouse movement taken at host time t, as the pump would record it.
void InjectGame(double t, double dx, double dy);

} // namespace Input
