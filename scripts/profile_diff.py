#!/usr/bin/env python3
"""Per-experiment GPU time change from a cvarbatch run with " profile" experiments.

    scripts/profile_diff.py RED4ext/runs/<timestamp>-cvarbatch [experiments.txt]

For experiment i the plugin wrote cvar<i>-exp and cvar<i>-base frame traces with GPU time per encoder
(scripts/gpu_profile.py). Prints, per experiment, the GPU busy time of both frames and the families that changed most.
"""
import contextlib
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu_profile  # noqa: E402


def summary(path):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        gpu_profile.main(path, 0)
    text = out.getvalue()
    busy = float(re.search(r"GPU busy ([0-9.]+) ms", text).group(1))
    fams = {m.group(1): float(m.group(2)) for m in re.finditer(r"^\| ([^|]+?) \| ([0-9.]+) \| [0-9]+% \|", text, re.M)}
    return busy, fams


def main(run, experiments=None):
    names = []
    if experiments:
        names = [l.split(" profile")[0].strip() for l in open(experiments) if l.strip() and not l.startswith("#")]
    metal = os.path.join(run, "metal")
    print("| Experiment | GPU busy exp / base (ms) | Change | Largest family changes (ms) |\n| --- | ---: | ---: | --- |")
    for i in range(64):
        exp, base = (os.path.join(metal, f"cvar{i}-{k}.trace.jsonl") for k in ("exp", "base"))
        if not (os.path.exists(exp) and os.path.exists(base)):
            if i > len(names):
                break
            continue
        (be, fe), (bb, fb) = summary(exp), summary(base)
        diffs = sorted(((fe.get(k, 0) - fb.get(k, 0), k) for k in set(fe) | set(fb)), key=lambda x: x[0])
        top = ", ".join(f"{k} {d:+.2f}" for d, k in diffs[:3] if abs(d) >= 0.05)
        name = names[i] if i < len(names) else f"cvar{i}"
        print(f"| {name} | {be:.2f} / {bb:.2f} | {be - bb:+.2f} | {top} |")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
