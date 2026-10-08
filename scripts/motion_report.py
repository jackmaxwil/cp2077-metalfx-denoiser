#!/usr/bin/env python3
"""Denoiser quality in motion, from motion runs (RED4ext: RTBENCH_SCENARIO=motion tools/rtbench <modes>).

    scripts/motion_report.py RED4ext/runs/<timestamp>-motion...

For each capture the plugin wrote the upscaler output 20 frames into the motion (move20), the frame after the camera
has been still for 15 frames (still15) and the frame 90 frames later (still90, converged). PSNR of still15 against still90 (higher is
better) measures what the motion left behind: ghosting, lag and noise in disoccluded areas; over the whole image, and
over the left and right 15% (where a turn brings in new content).
"""
import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def tool(run, name):
    out = os.path.join(run, name)
    if not os.path.exists(out):
        subprocess.run(["swiftc", "-O", os.path.join(HERE, name + ".swift"), "-o", out], check=True)
    return out


def main(runs):
    for run in runs:
        shots = {}
        for path in glob.glob(os.path.join(run, "metal", "*-*.png")):
            m = re.match(r"(s0-.+)-\d+-(move\d+|still15|still90)-\d+x\d+-[A-Za-z0-9]+\.png$", os.path.basename(path))
            if m:
                shots.setdefault(m.group(1), {})[m.group(2)] = path
        if not shots:
            continue
        diff = tool(run, "imgdiff")
        print(f"\n### {os.path.basename(run)}\n\n| Capture | PSNR still15 vs still90 (dB) | Edges only (dB) | MAE |\n| --- | ---: | ---: | ---: |")
        rows = {}
        for tag in sorted(shots):
            pair = shots[tag]
            if "still15" not in pair or "still90" not in pair:
                print(f"| {tag} | missing | | |")
                continue
            run_diff = lambda *extra: subprocess.run([diff, pair["still15"], pair["still90"], *extra],
                                                     capture_output=True, text=True, check=True).stdout.split()
            psnr, mae = run_diff()[:2]
            edge = run_diff("0", "0.15")[0]
            rows[tag] = float(psnr)
            print(f"| {tag} | {float(psnr):.2f} | {float(edge):.2f} | {float(mae):.2f} |")
        variants = {}
        for tag, psnr in rows.items():
            variants.setdefault(re.sub(r"\d+$", "", tag), []).append(psnr)
        print("\n| Variant | Mean PSNR (dB) |\n| --- | ---: |")
        for v, xs in sorted(variants.items()):
            print(f"| {v} | {sum(xs) / len(xs):.2f} |")


if __name__ == "__main__":
    main(sys.argv[1:])
