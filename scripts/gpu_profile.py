#!/usr/bin/env python3
"""GPU time per pass of one frame, from the plugin's "profile <name>" request (RED4ext: RTBENCH_SCENARIO=profile).

    scripts/gpu_profile.py RUN/metal/<name>.trace.jsonl [top]

Reads <name>.trace.jsonl (encoders with their "ts" sample index, dispatches and pipelines) and <name>.ts.json (GPU
timestamps at each encoder's start and end, and for render passes at their vertex and fragment stages' start and
end; same clock as the CPU, nanoseconds). Render passes are timed by their fragment stage. Prints the frame's GPU busy time
(union of the encoders' intervals; encoders on different command buffers can overlap), the time per family (sum of
encoder durations, so overlapping work counts twice) and the longest encoders with their kernels.
"""
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FAMILIES = [
    ("NRD", r"^(REBLUR|RELAX|SIGMA|REFERENCE)_|prepareNrd|convertNrd"),
    ("Path tracing: wavefront", r"(?i)wavefront|aapl_chs_main|rgs_reference"),
    ("Path tracing: SHaRC", r"(?i)sharc"),
    ("ReSTIR GI", r"(?i)restir"),
    ("RTXDI", r"(?i)rtxdi|lightSelection"),
    ("Ray traced shadows", r"rgs_shadow"),
    ("Ray traced reflections / GI", r"rgs_reflection|rgs_diffuse|rgs_importance|rayTracedHitShaderGI"),
    ("SSR", r"(?i)postfxSSR"),
    ("MetalFX", r"(?i)brnetv|metalfx|mfx"),
    ("Volumetrics", r"(?i)volumetric|fog|cloud"),
    ("Post-processing", r"(?i)postfx|bloom|tonemap|dof|motionblur|lensflare|chromatic"),
    ("Lights and culling", r"(?i)cluster|cull|light"),
    ("Particles and simulation", r"(?i)particle|wind|fluid|skinning"),
]


def family(names, kind):
    for label, pattern in FAMILIES:
        if any(re.search(pattern, n) for n in names):
            return label
    return {"r": "Raster passes", "p": "Raster passes", "b": "Copies", "a": "Acceleration structures"}.get(
        kind, "Other compute")


def main(path, top=30):
    events = [json.loads(line) for line in open(path) if line.strip()]
    ts = json.load(open(path.replace(".trace.jsonl", ".ts.json")))
    samples = ts["samples"]
    index = {}
    try:
        index = json.load(open(os.path.join(HERE, "shader_index.json")))
    except OSError:
        pass
    pipes = {e["id"]: e for e in events if e["e"] == "pipe"}

    def pipe_name(pso):
        p = pipes.get(pso, {})
        entry = index.get(p.get("lib", "").split("|")[-1])
        if isinstance(entry, dict):
            name = entry["name"] if entry.get("status") == "verified" else "~" + entry["name"]
        else:
            name = p.get("name") or "?"
        return name + (f"#{p['label']}" if p.get("label") else "")

    encoders, current = [], {}
    for e in events:
        if e["e"] == "eb" and "ts" in e:
            i = e["ts"]
            # Render passes: four samples (vertex start/end, fragment start/end); timed by their fragment stage, which
            # on a tile-based GPU is the pass's real work (the vertex stage can start long before it).
            a, z = (i + 2, i + 3) if e["kind"] in ("r", "p") else (i, i + 1)
            if z < len(samples) and samples[a] and samples[z] and samples[z] >= samples[a]:
                enc = {"kind": e["kind"], "start": samples[a], "end": samples[z], "names": collections.Counter()}
                if e["kind"] in ("r", "p") and samples[i] and samples[i + 1]:
                    enc["vertex"] = samples[i + 1] - samples[i]
                encoders.append(enc)
                current[e["enc"]] = enc
        elif e["e"] in ("d", "rps") and e.get("enc") in current:
            current[e["enc"]]["names"][pipe_name(e.get("pso"))] += 1
        elif e["e"] == "ee":
            current.pop(e.get("enc"), None)
    if not encoders:
        print("no timed encoders")
        return
    encoders.sort(key=lambda x: x["start"])
    busy, cur_s, cur_e = 0, encoders[0]["start"], encoders[0]["end"]
    for x in encoders[1:]:
        if x["start"] > cur_e:
            busy += cur_e - cur_s
            cur_s, cur_e = x["start"], x["end"]
        else:
            cur_e = max(cur_e, x["end"])
    busy += cur_e - cur_s
    span = max(x["end"] for x in encoders) - encoders[0]["start"]
    total = sum(x["end"] - x["start"] for x in encoders)
    ms = lambda ns: ns / 1e6
    print(f"## {os.path.basename(path)}\n")
    print(f"- {len(encoders)} timed encoders; GPU busy {ms(busy):.2f} ms (union), span {ms(span):.2f} ms, "
          f"sum of encoder times {ms(total):.2f} ms\n")
    fam = collections.defaultdict(lambda: [0, 0])
    for x in encoders:
        x["family"] = family(list(x["names"]), x["kind"])
        fam[x["family"]][0] += x["end"] - x["start"]
        fam[x["family"]][1] += 1
    print("| Family | GPU ms | Share of sum | Encoders |\n| --- | ---: | ---: | ---: |")
    for name, (t, n) in sorted(fam.items(), key=lambda kv: -kv[1][0]):
        print(f"| {name} | {ms(t):.2f} | {t / total:.0%} | {n} |")
    print(f"\n| Encoder (longest {top}) | Kind | Family | GPU ms | Kernels / pipelines |\n| ---: | --- | --- | ---: | --- |")
    for i, x in enumerate(sorted(encoders, key=lambda x: x["start"] - x["end"])[:top]):
        names = ", ".join(f"{n} x{c}" if c > 1 else n for n, c in x["names"].most_common(4))
        print(f"| {i + 1} | {x['kind']} | {x['family']} | {ms(x['end'] - x['start']):.2f} | {names[:160]} |")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 30)
