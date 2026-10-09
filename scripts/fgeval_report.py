#!/usr/bin/env python3
"""Frame interpolation quality from a framegen run's "fgeval" samples (FrameGen::Evaluate).

    scripts/fgeval_report.py RUN_DIR

Each sample: the interpolator's frame between N-2 and N (gen, with jitter 0 or the render jitter, j0/j1), the real
frame N-1 (real) and the two inputs. PSNR against the real frame, over the scene (HUD margins cropped), for the
generated frame and for two baselines: repeating frame N, and the average of N-2 and N. Needs numpy and Pillow.
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


def hud(path):
    """The HUD regions (minimap, quickslots, prompts) of a 16:10 frame."""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    h, w, _ = a.shape
    boxes = [(0.84, 0.05, 0.97, 0.27), (0.0, 0.78, 0.15, 0.97), (0.85, 0.76, 0.99, 0.86)]
    return np.concatenate([a[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)].reshape(-1, 3) for x0, y0, x1, y1 in boxes])


def psnr(a, b):
    mse = float(((a - b) ** 2).mean())
    return 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)


def main(run):
    files = glob.glob(os.path.join(run, "**", "*fgeval*-RGBA16Float.png"), recursive=True)
    samples = {}
    for f in files:
        m = re.search(r"fgeval(\d+)-(gen-[ju][01]|real|prev2|cur)-", os.path.basename(f))
        if m:
            samples.setdefault(int(m.group(1)), {})[m.group(2)] = f
    rows = {}
    print("| Sample | Variant | Generated | Repeat N | Average | Gain over average | HUD generated | HUD repeat N |\n"
          "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for i in sorted(samples):
        s = samples[i]
        gen = next((k for k in s if k.startswith("gen")), None)
        if not gen or not all(k in s for k in ("real", "prev2", "cur")):
            continue
        real, prev2, cur, g = load(s["real"]), load(s["prev2"]), load(s["cur"]), load(s[gen])
        pg, pr, pa = psnr(g, real), psnr(cur, real), psnr((prev2 + cur) / 2, real)
        hg, hr = psnr(hud(s[gen]), hud(s["real"])), psnr(hud(s["cur"]), hud(s["real"]))
        j = gen[-2:]
        rows.setdefault(j, []).append((pg, pr, pa, hg, hr))
        print(f"| {i} | {j} | {pg:.2f} | {pr:.2f} | {pa:.2f} | {pg - pa:+.2f} | {hg:.2f} | {hr:.2f} |")
    for j, r in rows.items():
        if r:
            m = np.mean(np.array(r), axis=0)
            print(f"\n{j}: generated {m[0]:.2f} dB, repeat {m[1]:.2f} dB, average {m[2]:.2f} dB; HUD generated {m[3]:.2f} dB, "
                  f"HUD repeat {m[4]:.2f} dB ({len(r)} samples)")


if __name__ == "__main__":
    main(sys.argv[1])
