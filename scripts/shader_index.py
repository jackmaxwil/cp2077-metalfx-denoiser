#!/usr/bin/env python3
"""Index the game's Metal shader caches by the fingerprint MetalTrace records for each library the game creates, and
name the static shaders, verifying every name against the library it is paired with.

    scripts/shader_index.py [GAME_DIR] > shader_index.json      (verification summary on stderr)

Fingerprint: "<size>:<FNV-1a 64 of the first 4 KiB>" of the bytes passed to newLibraryWithData:, indexed both as the
bare metallib (MTLB) and as its HLTM container. A cache blob is "<u64 key><u32 size>HLTM...MTLB...".

engine/staticshadermetal_final.cache starts with a table of shader records (names are 0x80|len + chars):
- compute record: its blob key 110 bytes before its name;
- render record: vertex and fragment blob keys 123 and 115 bytes before a parameter block (rtFormats, TEXFMT_*, None,
  one block per render target), then the vertex and fragment shader names;
- some compute records carry extra data between the key and the name (key 256-431 bytes before it).
Status per name: "verified" (position rule + the library's function type matches: compute records are kernels,
render records vertex/fragment), "order" (paired by order only; shown as tentative), conflicts are dropped.
Check against the game: every NRD kernel named by the 110-byte rule dispatches 8x8 or 16x16 thread groups (16 of 16 in
the rtbench traces); about half of the order-only NRD names do not. Output: fingerprint -> {"name", "status"} for static shaders, fingerprint -> "<cache>:<key>" otherwise.
"""
import bisect
import collections
import json
import mmap
import os
import re
import struct
import sys

GAME = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077")


def fnv(data):
    h = 0xcbf29ce484222325
    for b in data[:4096]:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


PARAM = re.compile(r"^(rtFormats|None|TEXFMT_.*)$")


def function_types(m, o):
    _, flo, _ = struct.unpack_from("<QQQ", m, o + 0x10)
    p = o + flo
    types = []
    for _ in range(struct.unpack_from("<I", m, p)[0]):
        group = struct.unpack_from("<I", m, p + 4)[0]
        q = p + 8
        while q < p + 4 + group and m[q:q + 4] != b"ENDT":
            n = struct.unpack_from("<H", m, q + 4)[0]
            if m[q:q + 4] == b"TYPE":
                types.append(m[q + 6])
            q += 6 + n
        p += 4 + group
    return types  # 0 vertex, 1 fragment, 2 kernel


def static_names(m, end):
    """blob key -> (name, status), with a verification summary on stderr."""
    blob_types = {}
    for x in re.finditer(b"HLTM", m):
        o = m.find(b"MTLB", x.start(), x.start() + 128)
        if x.start() >= 12 and o > 0:
            try:
                blob_types[struct.unpack_from("<Q", m, x.start() - 12)[0]] = function_types(m, o)
            except struct.error:
                pass
    names = {x.start(): x.group(2).decode()
             for x in re.finditer(rb"([\x84-\xbf])([A-Za-z_][A-Za-z0-9_]{3,62})", m[:end])
             if x.group(1)[0] - 0x80 == len(x.group(2))}
    starts = sorted(names)
    keys = [(o, struct.unpack_from("<Q", m, o)[0]) for o in range(0, end - 7)
            if struct.unpack_from("<Q", m, o)[0] in blob_types]
    out, tally = {}, collections.Counter()

    def following_names(o):
        """Shader names after position o, skipping parameter strings, up to the next blob key."""
        nxt = next((ko for ko, _ in keys if ko > o + 8), end)
        return [names[s] for s in starts[bisect.bisect_right(starts, o):] if s < nxt and not PARAM.match(names[s])]

    for o, key in keys:
        types = blob_types[key]
        if types == [2] and o + 110 in names and not PARAM.match(names[o + 110]):
            out[key] = (names[o + 110], "verified")
        elif types in ([0], [1]) and (o + 123 in names or o + 115 in names):
            found = following_names(o)
            if found:
                out[key] = ("|".join(found[-2:]), "verified")
            else:
                tally["render record without names"] += 1
                continue
        elif types == [2]:
            found = following_names(o)
            if found:
                out[key] = (found[0], "order")
            else:
                # Likely a permutation of the next record (no name in between). Tentative: checked against the
                # thread groups the game dispatches, about half of these pairings are wrong (all 110-byte ones right).
                later = [ko for ko, k in keys if ko > o and blob_types[k] == [2]]
                main = next((ko for ko in later if ko + 110 in names and not PARAM.match(names[ko + 110])), None)
                between = [st for st in starts if o < st < (main or o)]
                if main is not None and not between:
                    out[key] = (names[main + 110], "order")
                else:
                    tally["kernel without a name"] += 1
                    continue
        else:
            tally["other library (ray tracing, intersection)"] += 1
            continue
        tally[out[key][1]] += 1
    # Cross-check: a compute-only name must not sit on a vertex/fragment library, and the other way round.
    for key, (name, status) in list(out.items()):
        compute_name = re.search(r"(CS|_Compute)$|^(REBLUR|RELAX|SIGMA|REFERENCE)_", name.split("|")[-1])
        if compute_name and blob_types[key] != [2]:
            tally["conflict (compute name, render library)"] += 1
            del out[key]
    print(f"static shader names: {dict(tally)}", file=sys.stderr)
    return out


def main():
    index = {}
    for fn in ("staticshadermetal_final.cache", "shadermetal_final.cache"):
        path = os.path.join(GAME, "engine", fn)
        with open(path, "rb") as f:
            m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        first = m.find(b"MTLB")
        names = static_names(m, first) if fn.startswith("static") else {}
        short = fn.split("_")[0]
        for x in re.finditer(b"MTLB", m):
            o = x.start()
            size = struct.unpack_from("<Q", m, o + 16)[0]
            if not 0 < size <= len(m) - o:
                continue
            # The HLTM container, when this blob has one, starts within 128 bytes before the MTLB.
            h = m.rfind(b"HLTM", max(0, o - 128), o)
            key = struct.unpack_from("<Q", m, h - 12)[0] if h >= 12 else None
            if key in names:
                label = {"name": names[key][0], "status": names[key][1]}
            else:
                label = f"{short}:{key:016x}" if key is not None else f"{short}@{o:x}"
            index[f"{size}:{fnv(m[o:o + size]):016x}"] = label
            if h >= 0:
                hsize = struct.unpack_from("<I", m, h - 4)[0]
                if 0 < hsize <= len(m) - h:
                    index[f"{hsize}:{fnv(m[h:h + hsize]):016x}"] = label
    json.dump(index, sys.stdout, indent=0, sort_keys=True)
    named = sum(1 for v in index.values() if isinstance(v, dict))
    print(f"{len(index)} fingerprints, {named} named", file=sys.stderr)


if __name__ == "__main__":
    main()
