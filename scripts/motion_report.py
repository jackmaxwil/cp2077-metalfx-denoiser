#!/usr/bin/env python3
"""Denoiser quality in motion, from motion runs (RED4ext: RTBENCH_SCENARIO=motion tools/rtbench <modes>).

    scripts/motion_report.py RED4ext/runs/<timestamp>-motion...

For each capture the plugin wrote two upscaler outputs: the first frame after the camera stopped (still0) and the frame
90 frames later (still90, converged). PSNR between them (higher is better) measures what the motion left behind:
ghosting, lag and noise in disoccluded areas.
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
        for path in glob.glob(os.path.join(run, "metal", "*-still*.png")):
            m = re.match(r"(s0-.+)-\d+-(still0|still90)-\d+x\d+-[A-Za-z0-9]+\.png$", os.path.basename(path))
            if m:
                shots.setdefault(m.group(1), {})[m.group(2)] = path
        if not shots:
            continue
        diff = tool(run, "imgdiff")
        print(f"\n### {os.path.basename(run)}\n\n| Capture | PSNR still0 vs still90 (dB) | MAE |\n| --- | ---: | ---: |")
        rows = {}
        for tag in sorted(shots):
            pair = shots[tag]
            if "still0" not in pair or "still90" not in pair:
                print(f"| {tag} | missing | |")
                continue
            psnr, mae = subprocess.run([diff, pair["still0"], pair["still90"]], capture_output=True, text=True,
                                       check=True).stdout.split()[:2]
            rows[tag] = float(psnr)
            print(f"| {tag} | {float(psnr):.2f} | {float(mae):.2f} |")
        variants = {}
        for tag, psnr in rows.items():
            variants.setdefault(re.sub(r"\d+$", "", tag), []).append(psnr)
        print("\n| Variant | Mean PSNR (dB) |\n| --- | ---: |")
        for v, xs in sorted(variants.items()):
            print(f"| {v} | {sum(xs) / len(xs):.2f} |")


if __name__ == "__main__":
    main(sys.argv[1:])
