#!/usr/bin/env python3
"""Emit a deterministic manifest of a staged Mash payload.

U2 moves portable assembly out of the macOS adapter without changing what ships.
Proving that needs a before/after comparison of the payload itself, not of the
finished app: the app also contains Ghostty, signatures and plists that the
extraction does not touch.

    payload-manifest.py <resource-root> [--subtrees a,b,c] > manifest.txt

Each line is `<sha256|-> <mode> <size> <path>` for a regular file, or
`dir <mode> - <path>` for a directory. Symlinks are recorded with their target
so a relocation cannot hide inside one.

Hashes are skipped for files above --max-hash-bytes so a 52k-file defaults tree
stays fast; path, mode and size still catch additions, removals and moves.
"""

from __future__ import annotations

import hashlib
import os
import sys

# The parts of a payload that U2 extracts. Ghostty, the icon and the macOS
# uninstall script stay in the platform adapter, so comparing only these keeps
# the check about the extraction.
PORTABLE_SUBTREES = ("bin", "defaults", "libexec", "plugins")

DEFAULT_MAX_HASH = 2 * 1024 * 1024


def digest(path: str, max_bytes: int) -> str:
    size = os.path.getsize(path)
    if size > max_bytes:
        return "-"
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 256), b""):
            sha.update(chunk)
    return sha.hexdigest()


def walk(root: str, subtrees: tuple[str, ...], max_bytes: int) -> list[str]:
    lines: list[str] = []
    for name in sorted(os.listdir(root)):
        if subtrees and name not in subtrees:
            continue
        base = os.path.join(root, name)
        if not os.path.isdir(base) or os.path.islink(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            rel_dir = os.path.relpath(dirpath, root)
            mode = oct(os.stat(dirpath).st_mode & 0o777)
            lines.append(f"dir {mode} - {rel_dir}")
            for filename in sorted(filenames):
                full = os.path.join(dirpath, filename)
                rel = os.path.relpath(full, root)
                if os.path.islink(full):
                    lines.append(f"link {oct(os.lstat(full).st_mode & 0o777)} - {rel} -> {os.readlink(full)}")
                    continue
                stat = os.stat(full)
                lines.append(
                    f"{digest(full, max_bytes)} {oct(stat.st_mode & 0o777)} {stat.st_size} {rel}"
                )
    return lines


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        print(f"payload-manifest: {root} is not a directory", file=sys.stderr)
        return 1

    subtrees: tuple[str, ...] = PORTABLE_SUBTREES
    max_bytes = DEFAULT_MAX_HASH
    index = 2
    while index < len(argv):
        arg = argv[index]
        if arg == "--subtrees" and index + 1 < len(argv):
            subtrees = tuple(part for part in argv[index + 1].split(",") if part)
            index += 2
        elif arg == "--all":
            subtrees = ()
            index += 1
        elif arg == "--max-hash-bytes" and index + 1 < len(argv):
            max_bytes = int(argv[index + 1])
            index += 2
        else:
            print(f"payload-manifest: unknown argument {arg}", file=sys.stderr)
            return 2

    for line in walk(root, subtrees, max_bytes):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
