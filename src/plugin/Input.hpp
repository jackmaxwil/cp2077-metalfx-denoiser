#pragma once

#include <cstddef>

// Mouse input and the game's event pump (Input.mm). The game reads the mouse from AppKit events, which its main thread
// takes off the event queue once per game frame; GameController's GCMouse reports the same movement on a queue of our
// own as it happens, which is what frame warp (Warp.mm) needs. The pump hook also times the game's frames and can delay
// the game's input read (the game-thread delay: if the game thread reads input earlier than it needs to, waiting
// before the read makes the input it uses fresher).
namespace Input {

// Swizzles -[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:] (main thread).
void Start();
// Raw mouse movement from GCMouse on or off (frame warp turns it on; off detaches, in case it disturbs the game's own
// mouse events).
void SetRaw(bool on);

// Cumulative mouse movement at host time t (CACurrentMediaTime), from the last eight seconds: raw (GCMouse, as it
// happens) and as the game took it (AppKit event deltas, at the pump). False when t is outside the record.
bool Counts(double t, double& x, double& y);
bool GameCounts(double t, double& x, double& y);

// Wait this long (seconds, 0 = off) before the first event pump of each game frame.
void SetGameDelay(double seconds);
double GameDelay();

// Medians since the last call: the time between the game's pump bursts (its frame time) and how old mouse events were
// when the pump took them.
struct PumpStats {
    double frameMs = 0, eventAgeMs = 0;
    std::size_t bursts = 0;
};
PumpStats TakePumpStats();

// Tests: adds raw mouse movement at host time t, as GCMouse would.
void InjectRaw(double t, double dx, double dy);

} // namespace Input
