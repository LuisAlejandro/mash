#!/usr/bin/env python3
"""Rename the menu strings Ghostty bakes into its compiled nibs.

Ghostty's MainMenu.nib and About.nib are NIBArchive files, not property
lists, so plutil cannot touch them and nothing in the Command Line Tools can
recompile them (ibtool needs a full Xcode). Editing them here means rewriting
the archive directly.

The strings are stored inline as `\x08 <length> <utf-8 bytes>`, where the
length byte is 0x80 + the byte count, and the surrounding object table refers
to positions in the file. Changing a string's length would therefore shift
every later offset and require re-deriving that table. Every replacement
below is exactly three bytes shorter than its original ("Ghostty" is seven
bytes, "Mash" four), so padding each one back out by three bytes keeps the
length byte and every offset valid and needs no understanding of the table.

The padding is U+200B zero width space: it preserves the byte count while
rendering as nothing, which three literal spaces would not.

Idempotent: run it twice and the second run finds nothing to do. Exits
non-zero if a Ghostty string that is not a display name would be touched, or
if any of them survive the pass.
"""

import pathlib
import sys

# Display names only. Deliberately absent: '_TtC7Ghostty11AppDelegate' and
# '_TtC7Ghostty15AboutController' are Swift class names the nib resolves at
# load time, and 'toggleGhosttyFullScreen:' is an action selector. Renaming
# any of those breaks the app rather than rebranding it.
REPLACEMENTS = {
    "About Ghostty": "About Mash",
    "Hide Ghostty": "Hide Mash",
    "Quit Ghostty": "Quit Mash",
    "Ghostty Help": "Mash Help",
    "Make Ghostty the Default Terminal": "Make Mash the Default Terminal",
    # The app menu title and the About box's name. AppKit overrides the menu
    # title with CFBundleName at runtime, but it costs nothing to fix the
    # fallback too.
    "Ghostty": "Mash",
}

# Strings that legitimately keep the word Ghostty.
KEEP = {
    "_TtC7Ghostty11AppDelegate",
    "_TtC7Ghostty15AboutController",
    "toggleGhosttyFullScreen:",
}

PAD = "\u200b"
NIB_FILES = ("MainMenu.nib", "About.nib")


def inline_strings(data):
    """Yield (content_start, content_end, text) for every inline nib string."""
    for i in range(len(data) - 2):
        if data[i] != 0x08:
            continue
        length_byte = data[i + 1]
        if not 0x80 < length_byte < 0x80 + 0x7F:
            continue
        length = length_byte - 0x80
        blob = bytes(data[i + 2:i + 2 + length])
        if len(blob) != length:
            continue
        try:
            text = blob.decode("utf-8")
        except UnicodeDecodeError:
            continue
        yield i + 2, i + 2 + length, text


def pad_to(old, new):
    """Return `new` padded so it encodes to exactly as many bytes as `old`."""
    want = len(old.encode("utf-8")) - len(new.encode("utf-8"))
    if want < 0:
        raise SystemExit(f"replacement for {old!r} is longer than the original")
    return new + PAD * (want // len(PAD.encode("utf-8"))) + " " * (
        want % len(PAD.encode("utf-8"))
    )


def patch(path, reports):
    data = bytearray(path.read_bytes())
    edits = []
    for start, end, text in inline_strings(data):
        if text not in REPLACEMENTS:
            continue
        new = pad_to(text, REPLACEMENTS[text])
        if len(new.encode("utf-8")) != end - start:
            raise SystemExit(f"{path.name}: {text!r} would change length")
        edits.append((start, end, new.encode("utf-8")))

    for start, end, blob in edits:
        data[start:end] = blob
    if edits:
        path.write_bytes(bytes(data))
    reports.append(f"{path.name}: {len(edits)} string(s) renamed")

    # The real invariant: after the pass, no display string may still say
    # Ghostty. Only the class names and the selector above are allowed to.
    survivors = {
        text
        for _, _, text in inline_strings(data)
        if "Ghostty" in text and text not in KEEP
    }
    if survivors:
        raise SystemExit(f"{path.name}: still says Ghostty: {sorted(survivors)}")


def main(argv):
    if len(argv) != 2:
        raise SystemExit(f"usage: {argv[0]} <Ghostty.app or its Contents/Resources>")
    root = pathlib.Path(argv[1])
    if (root / "Contents" / "Resources").is_dir():
        root = root / "Contents" / "Resources"

    reports = []
    seen = 0
    total = 0
    for name in NIB_FILES:
        path = root / name
        if not path.is_file():
            continue
        found = sum(
            1
            for _, _, text in inline_strings(path.read_bytes())
            if text in REPLACEMENTS
        )
        seen += 1
        total += found
        patch(path, reports)

    if not seen:
        raise SystemExit(f"no nibs found under {root}")
    for line in reports:
        print(f"  {line}")
    if not total:
        print("  nothing left to rename")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
