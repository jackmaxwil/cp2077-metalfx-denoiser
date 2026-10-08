#!/usr/bin/env python3
"""Index the game's Metal shader caches by the fingerprint MetalTrace records for each library the game creates.

    scripts/shader_index.py [GAME_DIR] > shader_index.json

Fingerprint: "<size>:<FNV-1a 64 of the first 4 KiB>" of the bytes passed to newLibraryWithData:. Each cache blob is
indexed both as the bare metallib (MTLB, size from its header) and as its HLTM container, since either may be what the
game hands to Metal. Names: engine/staticshadermetal_final.cache starts with a table of records
(0x80|len, name, u32, 16 bytes, u64 key, ...); a blob is "<u64 key><u32 size>HLTM...MTLB...". Blobs with a named key
get that name (NRD, ray tracing, post-processing, ...); others are "<cache>:<key or offset>". In the table a record's
header (with its blob key) comes before its name, so a name owns the blob keys between the previous name and itself
(checked: the key before "REBLUR_Diffuse_TemporalAccumulation" holds REBLUR's s_Normal_MinHitDist).
"""
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


def static_names(m, end):
    keys = set()
    for x in re.finditer(b"HLTM", m):
        if x.start() >= 12:
            keys.add(struct.unpack_from("<Q", m, x.start() - 12)[0])
    names = {}
    prev = 0
    for x in re.finditer(rb"([\x84-\xbf])([A-Za-z_][A-Za-z0-9_]{3,62})", m[:end]):
        if x.group(1)[0] - 0x80 != len(x.group(2)):
            continue
        for o in range(prev, x.start() - 7):
            key = struct.unpack_from("<Q", m, o)[0]
            if key in keys:
                names[key] = x.group(2).decode()
        prev = x.end()
    return names


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
            label = names.get(key) if key in names else (f"{short}:{key:016x}" if key is not None else f"{short}@{o:x}")
            index[f"{size}:{fnv(m[o:o + size]):016x}"] = label
            if h >= 0:
                hsize = struct.unpack_from("<I", m, h - 4)[0]
                if 0 < hsize <= len(m) - h:
                    index[f"{hsize}:{fnv(m[h:h + hsize]):016x}"] = label
    json.dump(index, sys.stdout, indent=0, sort_keys=True)
    named = sum(1 for v in index.values() if ":" not in v and "@" not in v)
    print(f"{len(index)} fingerprints, {named} named", file=sys.stderr)


if __name__ == "__main__":
    main()
