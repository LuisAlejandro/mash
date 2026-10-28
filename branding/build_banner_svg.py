#!/usr/bin/env python3
"""Build branding/banner.svg, the README banner.

render_header_art.py owns the artwork: the same cells Ghostty draws in a Mash
pane, in the same colours. This script lays those cells out as SVG rectangles
on a 1190x265 canvas, the banner size the README expects, so the banner cannot
drift from the shipped header art.

Usage: build_banner_svg.py [OUT.svg]    (default: branding/banner.svg)
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE / "banner.svg"
WIDTH, HEIGHT = 1190, 265
# Fraction of the canvas height the art occupies, leaving a quiet margin.
# The art keeps the terminal's 8x18 cell ratio, so this is the only dial:
# widening the cell independently would stretch the wordmark horizontally.
ART_HEIGHT = 0.80

spec = importlib.util.spec_from_file_location("render_header_art", HERE / "render_header_art.py")
art = importlib.util.module_from_spec(spec)
spec.loader.exec_module(art)


def hex_colour(rgb):
    return "#%02x%02x%02x" % tuple(rgb)


def build(rows):
    cols = max(len(row) for row in rows)
    cell_h = HEIGHT * ART_HEIGHT / len(rows)
    cell_w = cell_h * art.CELL_W / art.CELL_H
    left = (WIDTH - cols * cell_w) / 2
    top = (HEIGHT - len(rows) * cell_h) / 2
    background = hex_colour(art.WINDOW_BG)

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}" role="img" aria-label="Mash">',
        "  <title>Mash</title>",
        f'  <rect width="{WIDTH}" height="{HEIGHT}" fill="{background}"/>',
        '  <g shape-rendering="crispEdges">',
    ]
    for gy, row in enumerate(rows):
        for gx, (ch, fg, bg) in enumerate(row):
            for colour, t0, t1 in art.cell_spans(ch, fg, bg):
                # The canvas already carries the window background.
                if colour == art.WINDOW_BG:
                    continue
                x = left + gx * cell_w
                y = top + gy * cell_h + t0 * cell_h
                h = (t1 - t0) * cell_h
                out.append(
                    f'    <rect x="{x:.2f}" y="{y:.2f}" width="{cell_w:.2f}" '
                    f'height="{h:.2f}" fill="{hex_colour(colour)}"/>'
                )
    out += ["  </g>", "</svg>", ""]
    return "\n".join(out)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    out.write_text(build(art.parse()), encoding="utf-8")
    print(f"wrote {out} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
