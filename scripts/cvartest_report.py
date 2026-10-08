#!/usr/bin/env python3
"""Config variable experiments (RED4ext: RTBENCH_SCENARIO=cvartest tools/rtbench <modes>) as Markdown.

    scripts/cvartest_report.py RED4ext/runs/<timestamp>-cvartest...

Per experiment: the variable change as the plugin applied it (metal/cvar.jsonl: before -> after, or why it was refused)
and GPU time per frame against the mean of the baselines measured right before and after it (one of them when the
other is missing).
"""
import json
import os
import sys


def main(runs):
    for run in runs:
        metal = os.path.join(run, "metal")
        if not os.path.isdir(metal):
            continue
        perf = {}
        for f in os.listdir(metal):
            if f.endswith(".perf.json"):
                d = json.load(open(os.path.join(metal, f)))
                perf[d["name"]] = d["gpu_ms"]["median"]
        changes = [json.loads(l) for l in open(os.path.join(metal, "cvar.jsonl"))] if os.path.exists(
            os.path.join(metal, "cvar.jsonl")) else []
        mode = next((k.split("-")[1] for k in perf if "-base" in k), "?")
        print(f"\n### {mode} ({os.path.basename(run)})\n")
        print("| Variable | Change | GPU ms | Baseline ms | Difference |\n| --- | --- | ---: | ---: | ---: |")
        sets = changes[0::2]  # set, restore, set, restore, ...
        for i, c in enumerate(sets):
            exp, b0, b1 = (perf.get(f"s0-{mode}-{t}") for t in (f"exp{i}", f"base{i}", f"base{i + 1}"))
            change = c.get("error") or f"{c['before']} -> {c['after']}"
            bases = [b for b in (b0, b1) if b is not None]
            if exp is None or not bases:
                print(f"| {c['var']} | {change} | - | - | - |")
                continue
            base = sum(bases) / len(bases)
            print(f"| {c['var']} | {change} | {exp:.2f} | {base:.2f} | {exp - base:+.2f} ({(exp - base) / base:+.0%}) |")


if __name__ == "__main__":
    main(sys.argv[1:])
