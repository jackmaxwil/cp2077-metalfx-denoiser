#!/usr/bin/env python3
"""Summarize rtbench runs (RED4ext tools/rtbench: one cp-run per ray tracing mode) as Markdown.

    scripts/rtbench_report.py RED4ext/runs/<timestamp>-rtbench... > report.md

Per spot and mode: GPU time per frame (median, 99th percentile) and frame time from metal/<tag>.perf.json; flicker as
PSNR / mean absolute error between the two still screenshots taken 2 s apart with time frozen (higher PSNR = steadier
image); a reference column when a run has s<spot>-ref-still-a.png (converged reference image). Pass lists for each
traced frame are written next to its run as metal/<tag>.passes.md (named through shader_index.json when present in
the run folder or next to this script).
"""
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def imgdiff_bin(run):
    out = os.path.join(run, "imgdiff")
    if not os.path.exists(out):
        subprocess.run(["swiftc", "-O", os.path.join(HERE, "imgdiff.swift"), "-o", out], check=True)
    return out


def diff(tool, a, b):
    if not (os.path.exists(a) and os.path.exists(b)):
        return None
    r = subprocess.run([tool, a, b, "0.06"], capture_output=True, text=True)
    try:
        psnr, mae = r.stdout.split()
        return float(psnr), float(mae)
    except ValueError:
        return None


def load_events(run):
    events = []
    try:
        for line in open(os.path.join(run, "autotest.log"), errors="replace"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return events


def frame_pipes(trace):
    """label -> [dispatches, threads, sample grid] for the compute dispatches of one traced frame."""
    events = [json.loads(line) for line in open(trace) if line.strip()]
    pipes = {e["id"]: e for e in events if e["e"] == "pipe"}
    out = {}
    for d in events:
        if d["e"] != "d" or d["pso"] not in pipes:
            continue
        p = pipes[d["pso"]]
        key = p.get("label") or p.get("name") or "?"
        g, t = d["g"], d["t"]
        threads = g[0] * g[1] * g[2] * (1 if d["mode"] == "th" else t[0] * t[1] * t[2])
        entry = out.setdefault(key, [0, 0, g])
        entry[0] += 1
        entry[1] += threads
    return out


def print_mode_only_passes(runs):
    """Compute pipelines (by the game's stable pipeline label) that run in a mode's spot-0 frame but not in raster's."""
    frames = {}
    for run in runs:
        for t in glob.glob(os.path.join(run, "metal", "s0-*.trace.jsonl")):
            frames[os.path.basename(t)[3:-len(".trace.jsonl")]] = frame_pipes(t)
    if "raster" not in frames:
        return
    base = frames["raster"]
    for mode, pipes in sorted(frames.items()):
        if mode == "raster":
            continue
        extra = {k: v for k, v in pipes.items() if k not in base}
        print(f"\n### Compute pipelines in {mode} but not raster (spot 0): {len(extra)}, "
              f"{sum(v[0] for v in extra.values())} dispatches, {sum(v[1] for v in extra.values()) / 1e6:.1f} M threads\n")
        print("| Pipeline label | Dispatches | Threads (M) | Grid of first dispatch |\n| --- | ---: | ---: | --- |")
        for k, (n, th, g) in sorted(extra.items(), key=lambda kv: -kv[1][1])[:40]:
            print(f"| {k} | {n} | {th / 1e6:.2f} | {g} |")


def main(runs):
    tool = imgdiff_bin(runs[0])
    print("# rtbench\n")
    rows, shots = [], {}
    for run in runs:
        events = load_events(run)
        for e in events:
            if e.get("event") == "BENCH_MODE":
                print(f"- `{os.path.basename(run)}`: mode {e['mode']} ({e['settings']})")
            if e.get("event") == "BENCH_SKIP":
                print(f"  - spot {e['spot']} skipped: no fast travel point named \"{e['name']}\" in this save")
            if e.get("event") == "BENCH_SPOT":
                rows.append((run, e))
        for path in glob.glob(os.path.join(run, "*.png")):
            shots[re.sub(r"^\d+-", "", os.path.basename(path))[:-4]] = path
    print("\n| Spot | Mode | GPU ms median | GPU ms p99 | Frame ms median | Frame ms p99 | Flicker PSNR dB | Flicker MAE | vs reference PSNR |"
          "\n| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for run, e in sorted(rows, key=lambda r: (r[1]["spot"], r[1]["mode"])):
        tag = f"s{e['spot']}-{e['mode']}"
        perf_path = os.path.join(run, "metal", f"{tag}.perf.json")
        perf = json.load(open(perf_path)) if os.path.exists(perf_path) else None
        flick = diff(tool, shots.get(f"{tag}-still-a", ""), shots.get(f"{tag}-still-b", ""))
        ref = diff(tool, shots.get(f"{tag}-still-a", ""), shots.get(f"s{e['spot']}-ref-still-a", ""))
        cells = [str(e["spot"]), e["mode"]]
        if perf:
            cells += [f"{perf['gpu_ms']['median']:.2f}", f"{perf['gpu_ms']['p99']:.2f}",
                      f"{perf['cpu_frame_ms']['median']:.2f}", f"{perf['cpu_frame_ms']['p99']:.2f}"]
        else:
            cells += ["-"] * 4
        cells += [f"{flick[0]:.2f}", f"{flick[1]:.2f}"] if flick else ["-", "-"]
        cells += [f"{ref[0]:.2f}"] if ref else ["-"]
        print("| " + " | ".join(cells) + " |")
    print_mode_only_passes(runs)
    index = next((p for p in [os.path.join(r, "shader_index.json") for r in runs] + [os.path.join(HERE, "shader_index.json")]
                  if os.path.exists(p)), None)
    traces = sorted(t for r in runs for t in glob.glob(os.path.join(r, "metal", "*.trace.jsonl")))
    if traces:
        print("\nPass lists:\n")
        for t in traces:
            md = re.sub(r"\.trace\.jsonl$", ".passes.md", t)
            with open(md, "w") as f:
                subprocess.run([sys.executable, os.path.join(HERE, "metal_passes.py"), t] + ([index] if index else []),
                               stdout=f, check=True)
            print(f"- {md}")


if __name__ == "__main__":
    main(sys.argv[1:])
