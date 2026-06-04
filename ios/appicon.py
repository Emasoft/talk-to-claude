#!/usr/bin/env python3
"""Generate the App Store / iOS app icon for Talk to Claude.

Re-runnable, like ios/project.rb — the PNG it writes is a build artifact, not a
hand-edited file. A clean white microphone on a warm coral gradient (no text,
no alpha — App Store icons must be opaque sRGB). Drawn at 4x and downsampled so
the edges are smooth.

    uv run --with pillow python ios/appicon.py

Writes a single 1024x1024 icon into the asset catalog; Xcode derives every
smaller size from it. Replace it with your own art any time — just keep the
filename and the 1024x1024 / opaque constraints.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).parent / "TalkToClaude" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
S = 1024            # final size
SS = 4              # supersample factor for anti-aliasing
N = S * SS          # working canvas size

TOP = (232, 133, 107)      # warm coral (top of gradient)
BOT = (191, 84, 60)        # deeper terracotta (bottom)
WHITE = (255, 255, 255)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        round(a[0] + (b[0] - a[0]) * t),
        round(a[1] + (b[1] - a[1]) * t),
        round(a[2] + (b[2] - a[2]) * t),
    )


def build() -> Image.Image:
    img = Image.new("RGB", (N, N), TOP)
    px = img.load()
    # Vertical gradient background.
    for y in range(N):
        row = lerp(TOP, BOT, y / (N - 1))
        for x in range(N):
            px[x, y] = row

    d = ImageDraw.Draw(img)

    def sc(v: float) -> float:
        return v * SS

    cx = sc(512)
    # Microphone capsule (a vertical pill).
    cap_w = sc(240)
    cap_top, cap_bot = sc(250), sc(560)
    d.rounded_rectangle(
        [cx - cap_w / 2, cap_top, cx + cap_w / 2, cap_bot],
        radius=cap_w / 2, fill=WHITE,
    )
    # Cradle: a U-shaped arc under the capsule.
    arc_box = [sc(330), sc(360), sc(694), sc(700)]
    d.arc(arc_box, start=18, end=162, fill=WHITE, width=int(sc(30)))
    # Stand.
    d.line([cx, sc(686), cx, sc(772)], fill=WHITE, width=int(sc(28)))
    # Base.
    d.rounded_rectangle(
        [cx - sc(95), sc(760), cx + sc(95), sc(792)],
        radius=sc(16), fill=WHITE,
    )

    return img.resize((S, S), Image.LANCZOS)


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon = build()
    # Opaque sRGB PNG, no alpha — App Store requirement.
    icon.save(OUT, format="PNG")
    print(f"Wrote {OUT} ({icon.size[0]}x{icon.size[1]}, mode={icon.mode})")


if __name__ == "__main__":
    main()
