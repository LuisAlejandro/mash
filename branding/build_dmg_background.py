#!/usr/bin/env python3
"""Build branding/dmg-background.png.

The 660x440 Finder window uses the same #272823 background and header art as
Mash. Finder draws the four staged items itself; the background supplies only
the brand at the top and the drag-to-Applications arrow in the middle.

Usage: build_dmg_background.py [OUT.png]
       (default: branding/dmg-background.png)
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE / "dmg-background.png"
WIDTH, HEIGHT = 660, 440

spec = importlib.util.spec_from_file_location("render_header_art", HERE / "render_header_art.py")
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)


def fill(px, x0, y0, x1, y1, colour):
    for y in range(max(0, y0), min(len(px), y1)):
        for x in range(max(0, x0), min(len(px[0]), x1)):
            px[y][x] = (*colour, 255)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    background = art.WINDOW_BG
    px = [[(*background, 255) for _ in range(WIDTH)] for _ in range(HEIGHT)]

    # The header word at its reference terminal cell size (208x180). Its own
    # background is the same as this canvas, so copying the rectangle is clean.
    logo = art.render(art.parse(), grid=True)
    left = (WIDTH - len(logo[0])) // 2
    top = 8
    for y, row in enumerate(logo):
        px[top + y][left:left + len(row)] = row

    # Drag arrow between Mash.app at x=170 and Applications at x=490. Keep it
    # behind the Finder icons and labels, with the same red ramp as the logo.
    arrow = art.mix((0xff, 0x55, 0x55), (0xaa, 0x00, 0x00), 0x80)
    fill(px, 275, 237, 374, 245, arrow)
    for step in range(24):
        half = step // 2
        fill(px, 374 + step, 229 + half, 375 + step, 254 - half, arrow)

    art.write_png(out, px)
    print(f"wrote {out} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
