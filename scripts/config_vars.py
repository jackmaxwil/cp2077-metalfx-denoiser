#!/usr/bin/env python3
"""List the game's ray tracing and denoising config variables by group (docs/CONFIG_VARS.md).

    scripts/config_vars.py > vars.txt

Reads the game binary through RED4ext.SDK's validate_addresses.read_macho. Each registration function loads a group
name string ("Editor/Denoising/NRD") and then its variables' names; every identifier string loaded after a group
string, in the same function (up to the next RET), is listed under that group.
"""
import bisect
import collections
import os
import re
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "RED4ext.SDK", "scripts"))
from validate_addresses import DEFAULT_BINARY, read_macho  # noqa: E402

L = read_macho(DEFAULT_BINARY)
data = L["data"]
base = L["segments"]["__TEXT"][0]
tvm, tsz = L["sections"][("__TEXT", "__text")]
cvm, csz = L["sections"][("__TEXT", "__cstring")]
cache = {}


def cstr(a):
    if a not in cache:
        o = a - base
        cache[a] = data[o:data.index(b"\0", o)].decode("latin1")
    return cache[a]


words = struct.unpack_from(f"<{tsz // 4}I", data, tvm - base)
seq = []  # string loads in code order; None marks a RET (function end)
for i, w in enumerate(words):
    if w == 0xD65F03C0:
        seq.append(None)
        continue
    if (w & 0x9F000000) != 0x90000000:  # ADRP
        continue
    imm = ((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)
    if imm & (1 << 20):
        imm -= 1 << 21
    page = ((tvm + 4 * i) & ~0xFFF) + (imm << 12)
    for j in range(1, 4):
        n = words[i + j]
        if (n & 0xFFC00000) == 0x91000000 and ((n >> 5) & 31) == (w & 31):  # ADD Xd, Xd, #imm
            t = page + ((n >> 10) & 0xFFF)
            if cvm <= t < cvm + csz:
                seq.append(t)
            break

group_re = re.compile(r"^[A-Z][A-Za-z0-9]*(/[A-Za-z0-9_]+)+$")
ident = re.compile(r"^[A-Z][A-Za-z0-9_]{2,60}$")
want = re.compile(r"^(RayTracing|Editor/(Denoising|PathTracing|RTXDI|ReGIR|SHARC|ReSTIRGI|ReSTIR))")
groups = collections.OrderedDict()
cur = None
for t in seq:
    if t is None:
        cur = None
        continue
    s = cstr(t)
    if group_re.match(s):
        cur = s
    elif cur and ident.match(s):
        names = groups.setdefault(cur, [])
        if s not in names:
            names.append(s)
for g in sorted(groups):
    if want.match(g):
        print(f"[{g}]\n  " + ", ".join(groups[g]))
