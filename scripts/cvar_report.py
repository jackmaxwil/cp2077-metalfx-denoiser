#!/usr/bin/env python3
"""Config variable experiments (RED4ext: RTBENCH_SCENARIO=cvarbatch tools/rtbench <modes>) as Markdown.

    scripts/cvar_report.py RED4ext/runs/<timestamp>-cvarbatch...

Per experiment: the change as the plugin applied it (metal/cvar.jsonl: before -> after, or why it was refused), GPU
time per frame against the mean of the baselines right before and after it, and how much the image changed against
the default (PSNR of the experiment's screenshot against the screenshot after restoring; higher = less change).
"""
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def psnr(tool, a, b):
    if not (a and b):
        return None
    out = subprocess.run([tool, a, b, "0.06"], capture_output=True, text=True).stdout.split()
    return float(out[0]) if out else None


def main(runs):
    tool = os.path.join(runs[0], "imgdiff")
    if not os.path.exists(tool):
        subprocess.run(["swiftc", "-O", os.path.join(HERE, "imgdiff.swift"), "-o", tool], check=True)
    for run in runs:
        metal = os.path.join(run, "metal")
        if not os.path.exists(os.path.join(metal, "cvar.jsonl")):
            continue
        perf = {json.load(open(f))["name"]: json.load(open(f))["gpu_ms"]["median"]
                for f in glob.glob(os.path.join(metal, "*.perf.json"))}
        shots = {re.sub(r"^\d+-", "", os.path.basename(p))[:-4]: p for p in glob.glob(os.path.join(run, "*.png"))}
        mode = next((json.loads(l).get("mode") for l in open(os.path.join(run, "autotest.log"))
                     if '"BENCH_MODE"' in l), "?")
        lines = [json.loads(l) for l in open(os.path.join(metal, "cvar.jsonl"))]
        print(f"\n### {mode} ({os.path.basename(run)}), before the batch {perf.get('cvar-pre', 0):.2f} ms\n")
        print("| Variable | Change | GPU ms | Baseline ms | Difference | Image vs default (PSNR dB) |\n"
              "| --- | --- | ---: | ---: | ---: | ---: |")
        # The plugin logs, per experiment in order: the change and its restore, or one refusal (an "error" line).
        k = 0
        for i in range(len(lines)):
            if k >= len(lines):
                break
            c = lines[k]
            k += 1 if "error" in c else 2
            tag = f"cvar{i}"
            exp = perf.get(f"{tag}-exp")
            bases = [b for b in (perf.get(f"cvar{i - 1}-base") if i else perf.get("cvar-pre"), perf.get(f"{tag}-base"))
                     if b is not None]
            change = c.get("error") or f"{c['before']} -> {c['after']}"
            if exp is None or not bases:
                print(f"| {c['var']} | {change} | - | - | - | - |")
                continue
            base = sum(bases) / len(bases)
            p = psnr(tool, shots.get(f"{tag}-exp"), shots.get(f"{tag}-base"))
            print(f"| {c['var']} | {change} | {exp:.2f} | {base:.2f} | {exp - base:+.2f} ({(exp - base) / base:+.0%}) | "
                  f"{p if p is not None else '-'} |")

if __name__ == "__main__":
    main(sys.argv[1:])
