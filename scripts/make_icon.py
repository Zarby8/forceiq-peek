#!/usr/bin/env python3
"""Draws Peek's app icon (the eyes mark on a black squircle) and writes Resources/AppIcon.icns.

Same shapes as the in-app mark (Sources/ForceIQPeak/EyesMark.swift): two white eyes with green pupils inside a green ring, on black,
with a thin gold rim. Brand colors only. Dev tool (needs Pillow and macOS iconutil); the .icns it writes is committed, so a build
never needs it.

    python3 peak/scripts/make_icon.py
"""
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

GOLD, GREEN, WHITE, BLACK = (0xF4, 0xC4, 0x30), (0x4F, 0xFF, 0x4F), (255, 255, 255), (0, 0, 0)
S = 2048                                   # draw at 2x of the 1024 master, then downsample
OUT = Path(__file__).resolve().parents[1] / "Resources" / "AppIcon.icns"


def master():
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    body = S * 824 // 1024                  # the macOS icon body inside its 1024 canvas
    x0 = (S - body) // 2
    r = int(body * 0.2237)
    d.rounded_rectangle([x0, x0, x0 + body, x0 + body], radius=r, fill=GOLD)           # gold is the outermost edge
    rim = int(S * 0.008)
    d.rounded_rectangle([x0 + rim, x0 + rim, x0 + body - rim, x0 + body - rim], radius=r - rim, fill=BLACK)
    c = S // 2
    ring_r = int(body * 0.40)               # the green ring around the mark
    ring_w = int(body * 0.034)
    d.ellipse([c - ring_r, c - ring_r, c + ring_r, c + ring_r], outline=GREEN, width=ring_w)
    disc = ring_r * 2 - ring_w * 2          # the mark's diameter, as `w` in EyesShape
    eye_w, eye_h = disc * 0.33 * 1.15, disc * 0.52 * 1.15
    spread = disc * 0.19 * 1.15
    pr = disc * 0.085 * 1.15
    for side in (-1, 1):
        cx = c + side * spread
        d.ellipse([cx - eye_w / 2, c - eye_h / 2, cx + eye_w / 2, c + eye_h / 2], fill=WHITE)
        px = cx + 0.55 * (eye_w / 2 - pr) * 0.9          # glancing a little to the right, like the idle pose
        d.ellipse([px - pr, c - pr, px + pr, c + pr], fill=GREEN)
    return im


def main():
    if sys.platform != "darwin":
        sys.exit("needs macOS iconutil")
    m = master()
    tmp = Path(os.environ.get("TMPDIR") or Path.home() / ".forceiq" / "tmp") / "peek-iconset" / "AppIcon.iconset"
    tmp.mkdir(parents=True, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            m.resize((px, px), Image.LANCZOS).save(tmp / f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(tmp), "-o", str(OUT)], check=True)
    print("wrote", OUT, OUT.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
