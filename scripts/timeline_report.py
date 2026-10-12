#!/usr/bin/env python3
"""Input lag parts from the plugin's frame timelines (request "timeline <frames>"; trace/timeline-<n>.jsonl).

    scripts/timeline_report.py timeline-0.jsonl [timeline-1.jsonl ...] [--labels a,b,...]

Per file, medians and 95th percentiles (ms) of: the frame interval (present to present); mouse event to the game's read;
frame start (the frame limit's release) to the present call (the game's CPU frame); read to the frame's last game GPU
work done (input to rendered); present call to GPU done (the GPU queue plus the frame's GPU tail); game and plugin GPU
busy per frame; and, on a visible display, the game's frame and its generated images shown (read to shown).
"""
import argparse
import json


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))] if v else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--labels")
    a = ap.parse_args()
    labels = a.labels.split(",") if a.labels else a.files
    cols = ["frame interval", "mouse to read", "CPU frame", "read to GPU done", "present call to GPU done",
            "game GPU busy", "plugin GPU busy", "read to frame shown", "read to first image shown"]
    print("| Run | " + " | ".join(cols) + " |\n| --- |" + " ---: |" * len(cols))
    for path, label in zip(a.files, labels):
        F = [json.loads(l) for l in open(path) if l.strip()]
        F = [f for f in F if f["present"] > 0 and f["game_gpu"][1] > 0]
        v = {c: [] for c in cols}
        for p, f in zip(F, F[1:]):
            v["frame interval"].append((f["present"] - p["present"]) * 1000)
        for f in F:
            done = f["game_gpu"][1]
            if f["read"] > 0 and f["event"] > 0:
                v["mouse to read"].append((f["read"] - f["event"]) * 1000)
            if f["start"] > 0 and f["present"] > f["start"]:
                v["CPU frame"].append((f["present"] - f["start"]) * 1000)
            if f["read"] > 0:
                v["read to GPU done"].append((done - f["read"]) * 1000)
                shown = [s for s in f["shown"] if s > 0]
                if f["shown"][3] > 0:
                    v["read to frame shown"].append((f["shown"][3] - f["read"]) * 1000)
                if shown:
                    v["read to first image shown"].append((min(shown) - f["read"]) * 1000)
            v["present call to GPU done"].append((done - f["present"]) * 1000)
            v["game GPU busy"].append(f["game_gpu"][2] * 1000)
            v["plugin GPU busy"].append(f["plugin_gpu"][2] * 1000)
        cells = []
        for c in cols:
            cells.append(f"{pct(v[c], .5):.1f} / {pct(v[c], .95):.1f}" if v[c] else "-")
        print(f"| {label} ({len(F)}) | " + " | ".join(cells) + " |")
    print("\nCells: median / 95th percentile, ms.")


if __name__ == "__main__":
    main()
