#!/usr/bin/env python3
"""Turn a MetalTrace frame trace (<name>.trace.jsonl) into a readable pass list (Markdown).

    scripts/metal_passes.py RUN/metal/s0-pt.trace.jsonl [shader_index.json] > s0-pt.md

Sections: totals; kernel families (dispatches, threads); MetalFX scaler calls; acceleration structure work; the pass
list in encoding order (per command buffer, encoder, and runs of the same kernel, with each bound texture's shader
name, access, size and format); and the denoiser-relevant inputs (bindings named like normals, roughness, albedo,
view depth, motion, hit distance).
"""
import collections
import json
import re
import sys

FAMILIES = [
    ("NRD REBLUR", r"^REBLUR_"), ("NRD RELAX", r"^RELAX_"), ("NRD SIGMA", r"^SIGMA_"), ("NRD reference", r"^REFERENCE_"),
    ("RTXDI", r"(?i)rtxdi"), ("ReSTIR GI", r"(?i)restir"), ("SHaRC", r"(?i)sharc"), ("Path tracing", r"(?i)rayTracedReference"),
    ("Ray tracing", r"(?i)raytrac|^rt[A-Z_]"), ("MetalFX", r"(?i)metalfx|^MTLFX"), ("FSR", r"(?i)fsr|ffx"),
]
ROLE = re.compile(r"(?i)normal|rough|albedo|viewz|depth|_mv\b|motion|hitdist|hit_dist|diff|spec|basecolor|metal")


# Library fingerprint -> shader name, from scripts/shader_index.py (optional).
INDEX = {}


def family(name):
    if name.startswith("~"):
        return "other"  # tentative names are not used for grouping
    for label, pattern in FAMILIES:
        if re.search(pattern, name or ""):
            return label
    return "other"


def main(path):
    events = [json.loads(line) for line in open(path) if line.strip()]
    tex = {e["id"]: e for e in events if e["e"] == "tex"}
    pipes = {e["id"]: e for e in events if e["e"] == "pipe"}
    begin = next((e for e in events if e["e"] == "begin"), {})

    def pipe_name(pso):
        p = pipes.get(pso)
        if not p:
            return f"?{pso}"
        name = p.get("name") or "?"
        lib = p.get("lib", "").split("|")[-1]
        label = f"#{p['label']}" if p.get("label") else ""
        entry = INDEX.get(lib)
        if isinstance(entry, dict):
            # Verified names as they are; "~": paired by table order only (scripts/shader_index.py).
            return (entry["name"] if entry["status"] == "verified" else f"~{entry['name']}") + label
        return f"{name}{label}"

    def tex_str(tid):
        t = tex.get(tid)
        if not t:
            return tid
        s = f"{t['w']}x{t['h']}" + (f"x{t['d']}" if t.get("d", 1) > 1 else "") + f" {t['fmt']}"
        if t.get("arr", 1) > 1:
            s += f" [{t['arr']}]"
        if t.get("mips", 1) > 1:
            s += f" mips{t['mips']}"
        return s

    def bindings(pso):
        out = {}
        for b in pipes.get(pso, {}).get("bindings", []):
            if b[0] == "tex":
                out[b[1]] = (b[2], b[3])
        return out

    dispatches = [e for e in events if e["e"] == "d"]
    print(f"# Frame trace: {path.rsplit('/', 1)[-1]}\n")
    named = sum(1 for d in dispatches if pipe_name(d["pso"])[:1] != "?")
    print(f"- Frame {begin.get('frame')}; {begin.get('pipes_named')} pipelines named since start")
    print(f"- Command buffers {len({e['cb'] for e in events if e['e'] in ('eb', 'commit') and 'cb' in e})}, "
          f"encoders {sum(1 for e in events if e['e'] == 'eb')}, dispatches {len(dispatches)} ({named} with a known kernel), "
          f"render pipeline binds {sum(1 for e in events if e['e'] == 'rps')}")

    def threads(d):
        g, t = d["g"], d["t"]
        return g[0] * g[1] * g[2] if d["mode"] == "th" else g[0] * g[1] * g[2] * t[0] * t[1] * t[2]

    fam = collections.defaultdict(lambda: [0, 0, set()])
    for d in dispatches:
        f = fam[family(pipe_name(d["pso"]))]
        f[0] += 1
        f[1] += threads(d)
        f[2].add(pipe_name(d["pso"]))
    print("\n## Kernel families\n\n| Family | Dispatches | Threads (M) | Kernels |\n| --- | ---: | ---: | ---: |")
    for name, (n, th, ks) in sorted(fam.items(), key=lambda kv: -kv[1][1]):
        print(f"| {name} | {n} | {th / 1e6:.1f} | {len(ks)} |")

    fx = [e for e in events if e["e"] == "fx"]
    if fx:
        print("\n## MetalFX scaler calls\n")
        for e in fx:
            fields = {k: tex_str(v) for k, v in e.items() if k in ("color", "depth", "motion", "output", "exposure", "reactive")}
            print(f"- {e['type']}: in {e.get('in')} content {e.get('content')} out {e.get('out')} jitter {e.get('jitter')} "
                  f"mvscale {e.get('mvscale')} depthReversed {e.get('depthReversed')} preExposure {e.get('preExposure')}")
            for k, v in fields.items():
                print(f"  - {k}: {v} ({e[k]})")

    accel = collections.Counter((e["op"], e.get("desc", "")) for e in events if e["e"] == "as")
    if accel:
        print("\n## Acceleration structures\n")
        for (op, desc), n in accel.most_common():
            print(f"- {op} {desc}: {n}")

    print("\n## Pass list (encoding order)\n")
    # The driver reuses encoder objects within a frame, so each "eb" starts a new encoder instance for that pointer.
    instances, current = [], {}
    for e in events:
        if e["e"] == "eb":
            current[e["enc"]] = len(instances)
            instances.append((e, []))
        elif e["e"] in ("d", "rps", "as", "icb", "use", "heap") and e["enc"] in current:
            instances[current[e["enc"]]][1].append(e)
    last_cb = None
    for eb, evs in instances:
        if eb.get("cb") != last_cb:
            last_cb = eb.get("cb")
            print(f"\n### Command buffer {last_cb}" + (f" ({eb['grp']})" if eb.get("grp") else ""))
        kind = {"c": "compute", "r": "render", "b": "blit", "a": "accel", "p": "parallel render"}.get(eb.get("kind"), "?")
        extra = ""
        if eb.get("rt"):
            extra = " targets " + ", ".join(tex_str(t) for t in eb["rt"])
        if eb.get("depth"):
            extra += f" depth {tex_str(eb['depth'])}"
        print(f"\n- {kind} encoder{extra}")
        reads, writes, heaps = [], [], 0
        for e in evs:
            if e["e"] == "use":
                (writes if e["usage"] & 2 else reads).extend(r for r in e["res"] if r in tex)
            elif e["e"] == "heap":
                heaps += len(e["heaps"])
        if reads or writes or heaps:
            print(f"  - uses: reads {', '.join(tex_str(t) for t in dict.fromkeys(reads)) or '-'}; "
                  f"writes {', '.join(tex_str(t) for t in dict.fromkeys(writes)) or '-'}" + (f"; heaps {heaps}" if heaps else ""))
        run = []

        def flush():
            if not run:
                return
            d = run[0]
            name = pipe_name(d["pso"])
            b = bindings(d["pso"])
            texs = "; ".join(
                f"t{slot} {b[slot][0]}({b[slot][1]})={tex_str(tid)}" if slot in b else f"t{slot}={tex_str(tid)}"
                for slot, tid in sorted(d["tex"]))
            flags = (" RT" if d.get("as") else "") + (f" [{d['grp']}]" if d.get("grp") else "")
            grid = d["g"] if d["mode"] != "ind" else "indirect"
            print(f"  - `{name}` x{len(run)} grid {grid} tg {d['t']}{flags}" + (f": {texs}" if texs else ""))
            run.clear()

        for e in evs:
            if e["e"] == "d":
                if run and run[0]["pso"] != e["pso"]:
                    flush()
                run.append(e)
            elif e["e"] in ("rps", "as", "icb"):
                flush()
                if e["e"] == "rps":
                    print(f"  - render pipeline `{pipe_name(e['pso'])}`")
                elif e["e"] == "as":
                    print(f"  - AS {e['op']} {e.get('desc', '')} geoms={e.get('geoms', '')} instances={e.get('instances', '')}")
                else:
                    print(f"  - indirect command buffer, {e['n']} commands")
        flush()

    print("\n## Denoiser-relevant bindings\n\n| Kernel | Slot | Name | Access | Texture |\n| --- | ---: | --- | --- | --- |")
    seen = set()
    for d in dispatches:
        name = pipe_name(d["pso"])
        if family(name) == "other":
            continue
        b = bindings(d["pso"])
        for slot, tid in sorted(d["tex"]):
            if slot in b and ROLE.search(b[slot][0]) and (name, slot) not in seen:
                seen.add((name, slot))
                print(f"| {name} | {slot} | {b[slot][0]} | {b[slot][1]} | {tex_str(tid)} |")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        INDEX.update(json.load(open(sys.argv[2])))
    main(sys.argv[1])
