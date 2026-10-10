#!/usr/bin/env python3
"""Camera warp check from a run's "warpeval" samples (FrameGen::WarpEval, 4x with camera warp).

    scripts/warpeval_report.py RUN_DIR

Each consecutive pair of game frames N, N+1 (wevNN-real): the warp turns frame N toward the input of about a frame
later, so the warped frame N (wevNN-warped) should be closer to frame N+1 than frame N is. PSNR over the scene (HUD
margins cropped). Needs numpy and Pillow.
"""
import glob
import os
import re
import sys

import numpy as np
from PIL import Image


def load(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = a.shape
    return a[int(h * 0.12):int(h * 0.80), int(w * 0.15):int(w * 0.85)]


def psnr(a, b):
    mse = float(((a - b) ** 2).mean())
    return 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)


def main(run):
    frames = {}
    for f in glob.glob(os.path.join(run, "**", "*wev*-RGBA16Float.png"), recursive=True):
        m = re.search(r"wev(\d+)-(real|warped)-", os.path.basename(f))
        if m:
            frames.setdefault(int(m.group(1)), {})[m.group(2)] = f
    rows = []
    print("| N | plain N vs N+1 | warped N vs N+1 | gain |\n| ---: | ---: | ---: | ---: |")
    for i in sorted(frames):
        a, b = frames[i], frames.get(i + 1, {})
        if "warped" not in a or "real" not in a or "real" not in b:
            continue
        nxt = load(b["real"])
        plain, warped = psnr(load(a["real"]), nxt), psnr(load(a["warped"]), nxt)
        rows.append((plain, warped))
        print(f"| {i} | {plain:.2f} | {warped:.2f} | {warped - plain:+.2f} |")
    if rows:
        m = np.mean(np.array(rows), axis=0)
        better = sum(w > p for p, w in rows)
        print(f"\nmean: plain {m[0]:.2f} dB, warped {m[1]:.2f} dB ({m[1] - m[0]:+.2f}); warped closer in {better} of {len(rows)}")


if __name__ == "__main__":
    main(sys.argv[1])
