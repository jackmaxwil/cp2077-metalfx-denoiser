#!/usr/bin/env python3
"""Image detail of each cvarbatch experiment against its baseline screenshot (same frozen spot).

    scripts/quality_report.py RUN_DIR [RUN_DIR ...]

For each cvar<i>-exp.png / cvar<i>-base.png pair: detail (mean absolute Laplacian of luma, higher = sharper textures and
edges), the ratio exp/base, and PSNR between them (how much the experiment changed the image). The HUD corners are
cropped out. Needs numpy and Pillow.
"""
import glob
import json
import os
import sys

import numpy as np
from PIL import Image


def luma(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = a.shape
    a = a[int(h * 0.12):int(h * 0.80), int(w * 0.15):int(w * 0.85)]  # skip HUD
    return a @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32), a


def detail(y):
    lap = 4 * y[1:-1, 1:-1] - y[:-2, 1:-1] - y[2:, 1:-1] - y[1:-1, :-2] - y[1:-1, 2:]
    return float(np.abs(lap).mean())


def psnr(a, b):
    mse = float(((a - b) ** 2).mean())
    return 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)


def experiments(run):
    names = {}
    path = os.path.join(run, "cvar-experiments.txt")
    for p in [path] + glob.glob(os.path.join(run, "**", "cvar-experiments.txt"), recursive=True):
        if os.path.exists(p):
            lines = [l.strip() for l in open(p) if l.strip() and not l.startswith("#") and "=" in l]
            return dict(enumerate(lines))
    return names


def main(runs):
    for run in runs:
        names = experiments(run)
        print(f"## {os.path.basename(run.rstrip('/'))}\n")
        print("| # | Experiment | Detail exp | Detail base | Ratio | PSNR exp vs base |\n| ---: | --- | ---: | ---: | ---: | ---: |")
        i = 0
        while True:
            exp = glob.glob(os.path.join(run, f"*cvar{i}-exp.png"))
            base = glob.glob(os.path.join(run, f"*cvar{i}-base.png"))
            if not exp or not base:
                if i > 64:
                    break
                i += 1
                continue
            ye, ce = luma(exp[0])
            yb, cb = luma(base[0])
            de, db = detail(ye), detail(yb)
            print(f"| {i} | {names.get(i, '?')} | {de:.4f} | {db:.4f} | {de / db:.3f} | {psnr(ce, cb):.1f} |")
            i += 1
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
