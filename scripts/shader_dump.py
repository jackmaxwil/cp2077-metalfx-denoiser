#!/usr/bin/env python3
"""Dump every Metal library in the game's shader caches (JSON lines, one library per line).

    scripts/shader_dump.py [GAME_DIR] > shader_dump.jsonl

Per library: cache file, offset, blob key (the u64 before its HLTM container, when it has one), fingerprint (as
MetalTrace records it: "<size>:<FNV-1a 64 of the first 4 KiB>"), functions (name, type, SHA-256 from the metallib
function list), and the identifiers that survive conversion (groupshared and global names: s_*, gs_*, g_*).

Metallib layout: "MTLB", 16-byte header, u64 file size, then (offset, size) pairs for the function list, public and
private metadata, and bitcode. The function list is a u32 count, then per function a u32 group size and tags
(4-char tag, u16 length, data) up to "ENDT": NAME, TYPE (0 vertex, 1 fragment, 2 kernel, 6 intersection), HASH, ...
"""
import json
import mmap
import os
import re
import struct
import sys

GAME = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077")
TYPES = {0: "vertex", 1: "fragment", 2: "kernel", 6: "intersection", 7: "mesh", 8: "object"}
IDENT = re.compile(rb"\b(?:gs_|s_|g_|cb_)[A-Za-z0-9_]{2,60}")


def fnv(data):
    h = 0xCBF29CE484222325
    for b in data[:4096]:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def functions(m, o):
    _, flo, _ = struct.unpack_from("<QQQ", m, o + 0x10)
    p = o + flo
    out = []
    for _ in range(struct.unpack_from("<I", m, p)[0]):
        group = struct.unpack_from("<I", m, p + 4)[0]
        q, end, tags = p + 8, p + 4 + group, {}
        while q < end and m[q:q + 4] != b"ENDT":
            n = struct.unpack_from("<H", m, q + 4)[0]
            tags[m[q:q + 4].decode("latin1")] = m[q + 6:q + 6 + n]
            q += 6 + n
        out.append({"name": tags.get("NAME", b"").rstrip(b"\0").decode("latin1"),
                    "type": TYPES.get(tags.get("TYPE", b"\xff")[0], "other"),
                    "hash": tags.get("HASH", b"").hex()[:16]})
        p = end
    return out


def main():
    for fn in ("staticshadermetal_final.cache", "shadermetal_final.cache"):
        with open(os.path.join(GAME, "engine", fn), "rb") as f:
            m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        for x in re.finditer(b"MTLB", m):
            o = x.start()
            size = struct.unpack_from("<Q", m, o + 16)[0]
            if not 0x58 < size <= len(m) - o:
                continue
            h = m.rfind(b"HLTM", max(0, o - 128), o)
            blob = m[o:o + size]
            try:
                funcs = functions(m, o)
            except struct.error:
                continue
            print(json.dumps({
                "cache": fn.split("_")[0], "offset": o,
                "key": f"{struct.unpack_from('<Q', m, h - 12)[0]:016x}" if h >= 12 else None,
                "fp": f"{size}:{fnv(blob):016x}", "functions": funcs,
                "ids": sorted({s.decode() for s in IDENT.findall(blob)})[:40],
            }))


if __name__ == "__main__":
    main()
