#!/usr/bin/env python3
"""CPU time per thread and per game function, from macOS `sample` output (sample <pid> 10 1 -file out.txt).

    scripts/cpu_profile.py SAMPLE.txt [--binary Cyberpunk2077.orig] [--top 25] [--json out.json]

The game binary has no symbols: each frame in Cyberpunk2077 is mapped to the function containing it (the nearest
LC_FUNCTION_STARTS entry at or below it, so addresses are function starts of the unslid binary, 0x100000000 based) and
named from RED4ext's address DB where it has a verified entry. Per thread: samples, how many were waiting (a leaf in
a blocking kernel call) and running; per running thread the game functions with the most self time (the innermost game
frame of each running sample) and inclusive time (on the stack). The plugin's own frames (MetalFXDenoiser.dylib) and
system libraries keep their symbols.
"""
import argparse
import collections
import json
import re
import struct
import sys
from bisect import bisect_right
from pathlib import Path

WAITS = ("__semwait_signal", "mach_msg2_trap", "mach_msg_trap", "__psynch_cvwait", "__psynch_mutexwait", "kevent",
         "__ulock_wait", "__workq_kernreturn", "semaphore_wait_trap", "semaphore_timedwait_trap", "__select",
         "__wait4", "poll", "read", "__read_nocancel", "nanosleep", "__ulock_wait2", "kevent_id", "kevent64",
         "__sigsuspend", "pread", "semaphore_wait_signal_trap", "swtch_pri", "thread_switch", "__psynch_rw_rdlock",
         "__psynch_rw_wrlock", "__recvfrom", "__recvmsg", "__accept", "mach_wait_until")
LINE = re.compile(r"^(?P<prefix>[ +!:|]*)(?P<count>\d+) (?P<sym>.*)$")
GAME = re.compile(r"\?\?\?  \(in Cyberpunk2077\)  load address (0x[0-9a-f]+) \+ (0x[0-9a-f]+)")
LIB = re.compile(r"^(?P<name>.*?)  \(in (?P<lib>[^)]+)\)")


def function_starts(binary: Path) -> list[int]:
    data = binary.read_bytes()
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit(f"{binary}: not a thin 64-bit Mach-O")
    off, text, starts_cmd = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19 and data[off + 8: off + 24].rstrip(b"\0") == b"__TEXT":
            text = struct.unpack_from("<Q", data, off + 24)[0]
        elif cmd == 0x26:
            starts_cmd = struct.unpack_from("<II", data, off + 8)
        off += size
    starts, p = [], starts_cmd[0]
    addr, end = text, starts_cmd[0] + starts_cmd[1]
    while p < end:
        delta = shift = 0
        while True:
            b = data[p]
            p += 1
            delta |= (b & 0x7F) << shift
            shift += 7
            if b < 0x80:
                break
        if delta == 0:
            break
        addr += delta
        starts.append(addr)
    return starts


def db_names(db: Path, sdk: Path) -> dict[int, str]:
    """Function start (unslid) -> name, for the address DB's entries named in the SDK's headers."""
    names_by_hash: dict[int, str] = {}
    rx = re.compile(r"constexpr\s+(?:std::)?uint32_t\s+(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)")
    for f in [*sdk.rglob("*.hpp")]:
        for n, v in rx.findall(f.read_text(errors="replace")):
            names_by_hash.setdefault(int(v, 0), n)
    out = {}
    if db.exists():
        for e in json.load(open(db)).get("Addresses", []):
            seg, o = e.get("offset", "0:0").split(":")
            h = int(e["hash"])
            if seg == "1" and h in names_by_hash:
                out[0x100000000 + int(o, 16)] = names_by_hash[h]
    return out


def parse(path: Path):
    """Threads: name -> list of (depth, count, symbol) in file order."""
    threads, cur = {}, None
    in_graph = False
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        if line.startswith("Call graph:"):
            in_graph = True
            continue
        if not in_graph:
            continue
        if not line.strip():
            if cur is not None:
                cur = None
            if threads and line == "":
                continue
        if line.startswith("Total number in stack") or line.startswith("Binary Images:"):
            break
        m = LINE.match(line[4:] if line.startswith("    ") else line)
        if not m:
            continue
        depth = len(m.group("prefix"))
        sym = m.group("sym")
        if depth == 0:
            cur = sym
            threads[cur] = []
            continue
        if cur is not None:
            threads[cur].append((depth, int(m.group("count")), sym))
    return threads


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sample")
    here = Path(__file__).resolve().parent
    game = Path.home() / "Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
    ap.add_argument("--binary", default=str(game / "Cyberpunk2077.orig"))
    ap.add_argument("--db", default=str(here.parent.parent / "RED4ext.SDK/cyberpunk2077_addresses.json"))
    ap.add_argument("--sdk", default=str(here.parent.parent / "RED4ext.SDK/include"))
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--json")
    args = ap.parse_args()
    starts = function_starts(Path(args.binary))
    names = db_names(Path(args.db), Path(args.sdk))

    def fn(sym: str) -> str:
        g = GAME.search(sym)
        if g:
            addr = 0x100000000 + int(g.group(2), 16)
            i = bisect_right(starts, addr) - 1
            f = starts[i] if i >= 0 else addr
            return f"game:0x{f:x}" + (f" {names[f]}" if f in names else "")
        m = LIB.match(sym)
        if m:
            lib = m.group("lib")
            name = re.sub(r"\s+\+ \d+.*$", "", m.group("name"))
            return f"{lib}:{name}"
        return sym

    report = {}
    threads = parse(Path(args.sample))
    total = max((sum(c for d, c, s in nodes if d == min(x[0] for x in nodes)) for nodes in threads.values() if nodes),
                default=1)
    rows = []
    for tname, nodes in threads.items():
        if not nodes:
            continue
        top = min(d for d, c, s in nodes)
        samples = sum(c for d, c, s in nodes if d == top)
        # Leaves: a node's self count is its count minus its children's.
        wait = run = 0
        self_game = collections.Counter()
        self_any = collections.Counter()
        incl_game = collections.Counter()
        # One pass: each node's own count is its count minus its direct children's (a child subtracts itself from
        # the node above it on the stack); a node is final once the walk leaves its subtree.
        own = [c for d, c, s in nodes]
        parent = [-1] * len(nodes)
        stack: list[int] = []
        for i, (d, c, s) in enumerate(nodes):
            while stack and nodes[stack[-1]][0] >= d:
                stack.pop()
            if stack:
                parent[i] = stack[-1]
                own[stack[-1]] -= c
            stack.append(i)
        for i, (d, c, s) in enumerate(nodes):
            if own[i] <= 0:
                continue
            leaf = s.split("  (in")[0].strip()
            if any(leaf.startswith(w) for w in WAITS):
                wait += own[i]
                continue
            run += own[i]
            self_any[fn(s)] += own[i]
            game_frames, k = [], i
            while k >= 0:
                if GAME.search(nodes[k][2]):
                    game_frames.append(fn(nodes[k][2]))
                k = parent[k]
            if game_frames:
                self_game[game_frames[0]] += own[i]
                for g in set(game_frames):
                    incl_game[g] += own[i]
        rows.append((run, tname, samples, wait, self_any, self_game, incl_game))
        report[tname] = {"samples": samples, "waiting": wait, "running": run,
                         "self": self_any.most_common(args.top), "game_self": self_game.most_common(args.top),
                         "game_inclusive": incl_game.most_common(args.top)}
    rows.sort(reverse=True)
    print(f"# CPU profile: {args.sample}\n\n{total} samples per thread (1 ms each).\n")
    print("| Thread | Running | Waiting |\n| --- | ---: | ---: |")
    for run, tname, samples, wait, *_ in rows[:30]:
        print(f"| {tname[:60]} | {run} ({100 * run / max(samples, 1):.0f}%) | {wait} |")
    for run, tname, samples, wait, self_any, self_game, incl_game in rows[:8]:
        if run < 0.05 * total:
            continue
        print(f"\n## {tname[:80]}: running {run} of {samples}\n")
        print("| Self (innermost frame) | Samples |\n| --- | ---: |")
        for k, v in self_any.most_common(args.top):
            print(f"| {k[:110]} | {v} |")
        print("\n| Game function, inclusive | Samples | Game function, self | Samples |\n| --- | ---: | --- | ---: |")
        inc, sf = incl_game.most_common(args.top), self_game.most_common(args.top)
        for i in range(max(len(inc), len(sf))):
            a = inc[i] if i < len(inc) else ("", "")
            b = sf[i] if i < len(sf) else ("", "")
            print(f"| {a[0]} | {a[1]} | {b[0]} | {b[1]} |")
    if args.json:
        json.dump(report, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
