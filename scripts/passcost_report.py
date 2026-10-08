#!/usr/bin/env python3
"""What parts of the frame cost, from passcost or denoise runs (RED4ext: RTBENCH_SCENARIO=passcost|denoise tools/rtbench <modes>).

    scripts/passcost_report.py RED4ext/runs/<timestamp>-passcost...

Each run measures GPU time per frame (sum of command buffer GPU times) and the frame interval (median of 180 frames) in rounds (passcost: off, listed, refit, raygen, metalfx;
denoise: off, pass, fx), then all again; a negative cost means the variant is slower than "off". GPU time drifts upward over a run (about 0.05-0.1 ms per round), so each round's baseline is the line through
the two "off" rounds; a part's cost is baseline minus the round's time, averaged over both repeats.
"""
import glob
import json
import os
import re
import sys

LABELS = {"listed": "listed shaders (skip-fingerprints.txt)", "refit": "acceleration structure refits",
          "raygen": "ray generation kernels (rgs_*)", "metalfx": "MetalFX temporal scaler",
          "pass": "denoise pass: RELAX dropped, noisy lighting passed through",
          "fx": "denoise fx: pass + MetalFX temporal denoised scaler"}


def main(runs):
    for metric in ("gpu_ms", "cpu_frame_ms"):
        print(f"\n## {'GPU time per frame (sum of command buffers)' if metric == 'gpu_ms' else 'Frame interval'}")
        report(runs, metric)


def report(runs, metric):
    for run in runs:
        times, skipped, order = {}, {}, []
        for path in sorted(glob.glob(os.path.join(run, "metal", "*.perf.json")), key=os.path.getmtime):
            d = json.load(open(path))
            m = re.match(r"s0-(.+)-([a-z]+)(\d)$", d["name"])
            if m and m.group(2) not in order:
                order.append(m.group(2))  # rounds in run order; the first ("off") is the baseline
            if m:
                mode, variant, rep = m.group(1), m.group(2), int(m.group(3))
                times[(variant, rep)] = d[metric]["median"]
                skipped[variant] = d.get("skipped_per_frame", 0)
        VARIANTS = order
        if ("off", 1) not in times or ("off", 2) not in times:
            continue
        n = len(VARIANTS)
        slope = (times[("off", 2)] - times[("off", 1)]) / n
        base = lambda variant, rep: times[("off", 1)] + slope * ((rep - 1) * n + VARIANTS.index(variant))
        frame = (times[("off", 1)] + times[("off", 2)]) / 2
        print(f"\n### {mode} ({os.path.basename(run)}): {frame:.2f} ms per frame, drift {slope:+.3f} ms per round\n")
        print("| Skipped | Dispatches/ops dropped per frame | Cost (ms) | Share | Repeats |\n| --- | ---: | ---: | ---: | --- |")
        for variant in VARIANTS[1:]:
            deltas = [base(variant, rep) - times[(variant, rep)] for rep in (1, 2) if (variant, rep) in times]
            if not deltas:
                continue
            cost = sum(deltas) / len(deltas)
            print(f"| {LABELS.get(variant, variant)} | {skipped.get(variant, 0):.0f} | {cost:.2f} | {cost / frame:.0%} | "
                  f"{', '.join(f'{x:.2f}' for x in deltas)} |")


if __name__ == "__main__":
    main(sys.argv[1:])
