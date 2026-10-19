#!/usr/bin/env python3
"""Build packaging/Mash.icns from the header art.

render_header_art.py draws the art. This script lays it out on Apple's macOS
app-icon grid, an 824 px tile centred in a transparent 1024 px canvas, and
packs every size iconutil expects. macOS 26 rescales any icon to that grid
when it draws it. macOS 14 and 15, which Mash still supports, draw the canvas
as-is, so a tile that filled it would look bigger than the other apps.

Sizes below 1024 px are box-filtered down from the 1024 px canvas.

Usage: build_icns.py [OUT.icns]    (default: packaging/Mash.icns)
"""

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE.parent / "packaging" / "Mash.icns"
CANVAS, TILE = 1024, 824

spec = importlib.util.spec_from_file_location("render_header_art", HERE / "render_header_art.py")
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)

# iconutil's name for each representation, and its pixel size.
SIZES = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]


def halve(px):
    """Halve an RGBA image with a 2x2 box filter. Colour is weighted by
    alpha, so the transparent margin does not darken the tile's edge."""
    out = []
    for y in range(0, len(px), 2):
        r0, r1 = px[y], px[y + 1]
        row = []
        for x in range(0, len(r0), 2):
            ps = (r0[x], r0[x + 1], r1[x], r1[x + 1])
            a = sum(p[3] for p in ps)
            if a == 0:
                row.append((0, 0, 0, 0))
            else:
                row.append(tuple(round(sum(p[i] * p[3] for p in ps) / a) for i in range(3)) + (round(a / 4),))
        out.append(row)
    return out


def small_m_icon(rows):
    """A legible 16 px monogram.

    The complete word is readable at 32 px but collapses into a red blur at
    16 px. Use an intentional 10x10 pixel M there, on the same 14 px macOS
    tile. Its five two-row colour bands come from the ANSI art's own shade
    ladder, so it still belongs to the same logo.
    """
    pattern = [
        "##......##",
        "###....###",
        "####..####",
        "##.####.##",
        "##..##..##",
        "##......##",
        "##......##",
        "##......##",
        "##......##",
        "##......##",
    ]
    bright = next(fg for row in rows for _, fg, _ in row if fg is not None)
    dark = next(fg for row in reversed(rows) for _, fg, _ in row if fg is not None)
    tones = [
        bright,
        art.mix(bright, dark, art.SHADE_ALPHA["▓"]),
        art.mix(bright, dark, art.SHADE_ALPHA["▒"]),
        art.mix(bright, dark, art.SHADE_ALPHA["░"]),
        dark,
    ]
    size, edge, offset, radius = 16, 14, 1, 3
    px = [[(0, 0, 0, 0) for _ in range(size)] for _ in range(size)]
    background = (*art.WINDOW_BG, 255)
    for y in range(edge):
        for x in range(edge):
            dx = max(radius - x, x - (edge - 1 - radius), 0)
            dy = max(radius - y, y - (edge - 1 - radius), 0)
            if dx * dx + dy * dy <= radius * radius:
                px[offset + y][offset + x] = background
    top = left = 3
    for y, row in enumerate(pattern):
        colour = (*tones[y // 2], 255)
        for x, mark in enumerate(row):
            if mark == "#":
                px[top + y][left + x] = colour
    return px


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    rows = art.parse()
    tile = art.render(rows, TILE)
    offset = (CANVAS - TILE) // 2
    canvas = [[(0, 0, 0, 0)] * CANVAS for _ in range(CANVAS)]
    for y, row in enumerate(tile):
        canvas[offset + y][offset:offset + TILE] = row
    levels = {CANVAS: canvas}
    size = CANVAS
    while size > 16:
        levels[size // 2] = halve(levels[size])
        size //= 2
    # Only the true 16 px representation gets the monogram. A 16 pt icon on a
    # Retina display selects icon_16x16@2x (32 px), where the word is readable.
    levels[16] = small_m_icon(rows)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Mash.iconset"
        iconset.mkdir()
        for name, px in SIZES:
            art.write_png(iconset / f"{name}.png", levels[px])
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
