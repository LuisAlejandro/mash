#!/usr/bin/env python3
"""Fail the build if a compiled nib still shows the word Ghostty to a user.

The fork owns the menu strings now: macos/Sources/App/MainMenu.xib ships "About
Mash", "Hide Mash", "Quit Mash" and "Mash Help", and Xcode compiles them into
MainMenu.nib. This script used to rewrite those strings in the built archive,
back when Mash took Ghostty's own nibs unchanged; that pass now finds nothing
and the rename has a single owner again.

What is still worth running is the invariant the rewrite protected: after the
build, no display string in a nib may say Ghostty. A nib is a NIBArchive, not a
property list, so plutil cannot read it and nothing in the Command Line Tools
recompiles it -- the strings are read out of the archive directly.

Strings are stored inline as `\x08 <length> <utf-8 bytes>`, where the length
byte is 0x80 + the byte count.

Usage: check-nib-branding.py <Ghostty.app or its Contents/Resources>
"""

import pathlib
import sys

# Strings that legitimately keep the word Ghostty: two Swift class names the
# nib resolves at load time, and one action selector. Renaming any of them
# breaks the app rather than rebranding it.
KEEP = {
    "_TtC7Ghostty11AppDelegate",
    "_TtC7Ghostty15AboutController",
    "toggleGhosttyFullScreen:",
}

NIB_FILES = ("MainMenu.nib", "About.nib")


def inline_strings(data):
    """Yield every inline nib string."""
    for i in range(len(data) - 2):
        if data[i] != 0x08:
            continue
        length_byte = data[i + 1]
        if not 0x80 < length_byte < 0x80 + 0x7F:
            continue
        length = length_byte - 0x80
        blob = bytes(data[i + 2 : i + 2 + length])
        if len(blob) != length:
            continue
        try:
            yield blob.decode("utf-8")
        except UnicodeDecodeError:
            continue


def main(argv):
    if len(argv) != 2:
        raise SystemExit(f"usage: {argv[0]} <Ghostty.app or its Contents/Resources>")
    root = pathlib.Path(argv[1])
    if (root / "Contents" / "Resources").is_dir():
        root = root / "Contents" / "Resources"

    seen = 0
    failed = False
    for name in NIB_FILES:
        path = root / name
        if not path.is_file():
            continue
        seen += 1
        survivors = sorted(
            {
                text
                for text in inline_strings(path.read_bytes())
                if "Ghostty" in text and text not in KEEP
            }
        )
        if survivors:
            failed = True
            print(f"  {name}: still says Ghostty: {survivors}", file=sys.stderr)
        else:
            print(f"  {name}: no Ghostty display strings")

    if not seen:
        raise SystemExit(f"no nibs found under {root}")
    if failed:
        raise SystemExit(
            "the fork's MainMenu.xib is what renames these; fix it there "
            "rather than rewriting the built archive"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
