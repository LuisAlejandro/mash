#!/usr/bin/env python3
"""Render Mash's hicolor icon set from the committed 1024x1024 source.

The desktop entry names one icon id, so every size must exist under that name
or a launcher falls back to a generic terminal icon. Resampling from Mash's own
artwork (branding/logo-solid.png) keeps the upstream Ghostty logo out of the
package entirely.

    render-icons.py <source.png> <hicolor-dir> <icon-id>
"""

from __future__ import annotations

import sys
from pathlib import Path

# The sizes a GNOME desktop actually reads, including the @2 variants that are
# named by directory rather than by filename.
SIZES = (16, 24, 32, 48, 64, 128, 256, 512)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source, hicolor, icon_id = Path(argv[1]), Path(argv[2]), argv[3]

    try:
        from PIL import Image
    except ImportError:
        print("render-icons.py needs Pillow; install python3-pil", file=sys.stderr)
        return 1

    if not source.is_file():
        print(f"missing icon source {source}", file=sys.stderr)
        return 1

    with Image.open(source) as original:
        art = original.convert("RGBA")
        if art.width != art.height:
            print(f"{source} is not square ({art.width}x{art.height})", file=sys.stderr)
            return 1
        for size in SIZES:
            for scale, suffix in ((1, ""), (2, "@2")):
                pixels = size * scale
                if pixels > art.width:
                    continue
                out = hicolor / f"{size}x{size}{suffix}" / "apps" / f"{icon_id}.png"
                out.parent.mkdir(parents=True, exist_ok=True)
                art.resize((pixels, pixels), Image.LANCZOS).save(out, "PNG", optimize=True)
    print(f"rendered {icon_id} icons from {source}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
