#!/usr/bin/env python3
"""Render packaging/defaults/pi/extensions/header-art.ansi the way Ghostty draws it.

Every cell is drawn from the art file's own data, with no hand-tuned colours:

- The background colour is painted only on cells that set one (48;2;r;g;b).
  Cells that set none show the window background, #272823.
- `█` fills the whole cell. `▀` fills the top half, `▄` the bottom half.
- `░ ▒ ▓` fill the whole cell with the foreground at 0x40, 0x80 and 0xc0
  alpha over the cell background. Ghostty draws them that way
  (src/font/sprite/draw/block.zig, fullBlockShade). The gradient on the
  letters therefore comes from the art itself.

Usage: render_header_art.py OUT.png [SIZE] [--grid]
  SIZE    canvas edge in pixels (default 1024, the macOS icon master)
  --grid  draw only the art, one 8x18 px tile per cell, the reference
          screenshot's cell size, for a pixel comparison
"""

import re
import struct
import sys
import zlib
from pathlib import Path

ART = Path(__file__).resolve().parent.parent / "packaging/defaults/pi/extensions/header-art.ansi"
WINDOW_BG = (0x27, 0x28, 0x23)
SHADE_ALPHA = {"░": 0x40, "▒": 0x80, "▓": 0xC0}
# Cell size measured from the reference screenshot (MesloLGS NF 14 in Ghostty).
CELL_W, CELL_H = 8, 18


def parse(path=ART):
    """Rows of (glyph, fg, bg). Each SGR sequence resets, then sets fg/bg."""
    rows = []
    for line in path.read_text(encoding="utf-8").split("\n"):
        if not line.strip():
            continue
        fg = bg = None
        cells = []
        for part in re.split(r"(\x1b\[[0-9;]*m)", line):
            if part.startswith("\x1b["):
                params = [int(p) for p in part[2:-1].split(";") if p != ""] or [0]
                i = 0
                while i < len(params):
                    p = params[i]
                    if p == 0:
                        fg = bg = None
                    elif p in (38, 48) and i + 4 < len(params) and params[i + 1] == 2:
                        colour = tuple(params[i + 2 : i + 5])
                        if p == 38:
                            fg = colour
                        else:
                            bg = colour
                        i += 4
                    elif p == 39:
                        fg = None
                    elif p == 49:
                        bg = None
                    i += 1
            else:
                cells.extend((ch, fg, bg) for ch in part)
        rows.append(cells)
    while rows and all(ch == " " for ch, _, _ in rows[-1]):
        rows.pop()
    return rows


def mix(fg, bg, alpha):
    t = alpha / 255
    return tuple(round(f * t + b * (1 - t)) for f, b in zip(fg, bg))


def cell_spans(ch, fg, bg):
    """What a terminal paints in one cell: (colour, top, bottom) spans,
    with top and bottom as fractions of the cell height."""
    under = bg if bg is not None else WINDOW_BG
    spans = [(under, 0.0, 1.0)]
    if fg is None or ch == " ":
        return spans
    if ch == "█":
        spans.append((fg, 0.0, 1.0))
    elif ch == "▀":
        spans.append((fg, 0.0, 0.5))
    elif ch == "▄":
        spans.append((fg, 0.5, 1.0))
    elif ch in SHADE_ALPHA:
        spans.append((mix(fg, under, SHADE_ALPHA[ch]), 0.0, 1.0))
    else:
        raise SystemExit(f"unexpected glyph {ch!r} in the art")
    return spans


def write_png(path, px):
    h, w = len(px), len(px[0])
    raw = b"".join(b"\x00" + b"".join(bytes(p) for p in row) for row in px)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def render(rows, size=1024, grid=False):
    cols = max(len(r) for r in rows)
    if grid:
        cw, ch_ = CELL_W, CELL_H
        width, height, left, top = cols * cw, len(rows) * ch_, 0, 0
        px = [[(*WINDOW_BG, 255) for _ in range(width)] for _ in range(height)]
    else:
        # Keep the terminal's cell shape. The reference screenshot's cells
        # are 8 px wide and 18 px tall. Fit the art inside the ~80% safe area
        # of a macOS icon.
        cw = min((size * 80 // 100) // cols, int((size * 80 // 100) * CELL_W / CELL_H) // len(rows))
        ch_ = round(cw * CELL_H / CELL_W)
        width = height = size
        left = (size - cols * cw) // 2
        top = (size - len(rows) * ch_) // 2
        radius = size * 225 // 1024
        px = [[(0, 0, 0, 0)] * size for _ in range(size)]
        for y in range(size):
            row = px[y]
            dy = max(radius - y, y - (size - 1 - radius), 0)
            for x in range(size):
                dx = max(radius - x, x - (size - 1 - radius), 0)
                if dx * dx + dy * dy <= radius * radius:
                    row[x] = (*WINDOW_BG, 255)
    for gy, row in enumerate(rows):
        for gx, (ch, fg, bg) in enumerate(row):
            x0 = left + gx * cw
            y0 = top + gy * ch_
            for colour, t0, t1 in cell_spans(ch, fg, bg):
                ya = y0 + round(t0 * ch_)
                yb = y0 + round(t1 * ch_)
                c = (*colour, 255)
                for y in range(ya, yb):
                    line = px[y]
                    for x in range(x0, x0 + cw):
                        line[x] = c
    return px


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    size = int(args[1]) if len(args) > 1 else 1024
    rows = parse()
    write_png(args[0], render(rows, size, grid="--grid" in sys.argv))
    print(f"wrote {args[0]}: {len(rows)} rows x {max(len(r) for r in rows)} cols")
