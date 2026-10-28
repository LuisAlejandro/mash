#!/usr/bin/env python3
"""Check that every Mash menu item sends a chord Herdr actually binds.

Mash's menus do not call Herdr. Each item replays the keystroke a user would
type, through the `mash_send_key` binding action, so an item only works while
its chord is still the one the shipped Herdr config binds. Nothing else
connects the two: the menu tables live in the Ghostty fork, the bindings live
in this repository, and a chord renamed on one side leaves an item that opens a
menu, does nothing, and reports no error.

Both platforms are checked from their own sources:

  macOS  macos/Sources/App/MashMenus.swift  vs  defaults/herdr/config.toml
  Linux  src/apprt/gtk/ui/1.5/window.blp    vs  defaults/herdr/config.linux.toml

Usage: menu-chords.py <ghostty-src> [<packaging-dir>]
Exits non-zero and names every offending item.
"""

import pathlib
import re
import sys
import tomllib

# Ghostty's key names for the keys Herdr spells differently. Modifier order is
# irrelevant on both sides, so chords are compared as a set of parts.
KEY_ALIASES = {
    "bracket_left": "[",
    "bracket_right": "]",
    "arrow_up": "up",
    "arrow_down": "down",
    "arrow_left": "left",
    "arrow_right": "right",
    "backslash": "\\",
    "minus": "-",
}
# Herdr writes Command as `cmd`; Ghostty accepts `cmd` as an alias for `super`.
MOD_ALIASES = {"super": "cmd", "command": "cmd", "option": "alt", "control": "ctrl"}


def normalise(chord):
    parts = []
    for part in chord.strip().lower().split("+"):
        part = MOD_ALIASES.get(part, part)
        parts.append(KEY_ALIASES.get(part, part))
    mods = sorted(p for p in parts if p in ("cmd", "ctrl", "alt", "shift"))
    keys = [p for p in parts if p not in ("cmd", "ctrl", "alt", "shift")]
    return "+".join(mods + keys)


def herdr_chords(path):
    """Every chord the shipped Herdr config binds, built-in actions and commands."""
    keys = tomllib.loads(path.read_text(encoding="utf-8")).get("keys", {})
    found = set()
    for name, value in keys.items():
        if name == "command":
            continue
        for chord in value if isinstance(value, list) else [value]:
            # "cmd+ctrl+1..9" is a range, not a chord an item can send.
            if isinstance(chord, str) and chord and ".." not in chord:
                found.add(normalise(chord))
    for command in keys.get("command", []):
        chords = command.get("key", [])
        for chord in chords if isinstance(chords, list) else [chords]:
            if chord and ".." not in chord:
                found.add(normalise(chord))
    return found


def macos_items(src):
    """(label, chord) for every macOS menu entry and the three app-menu chords."""
    text = (src / "macos/Sources/App/MashMenus.swift").read_text(encoding="utf-8")
    items = [
        (label, chord)
        for label, chord in re.findall(r'\.item\("([^"]+)",\s*"([^"]+)"\)', text)
    ]
    for name, chord in re.findall(r'static let (\w+)Chord = "([^"]+)"', text):
        items.append((name, chord))
    return items


def linux_items(src):
    """(label, chord) for every GTK menu item that replays a chord."""
    text = (src / "src/apprt/gtk/ui/1.5/window.blp").read_text(encoding="utf-8")
    items = []
    for label, body in re.findall(
        r'label:\s*_\("([^"]+)"\);(.*?)(?=\n\s*label:|\Z)', text, re.S
    ):
        if "win.mash-send-key" not in body:
            continue  # a real GTK action, not a chord replay
        target = re.search(r'target:\s*"([^"]+)"', body)
        if target:
            items.append((label, target.group(1)))
    # Reload is a Zig action that sends Herdr's chord itself.
    window = (src / "src/apprt/gtk/class/window.zig").read_text(encoding="utf-8")
    for chord in re.findall(r'mash_send_key = "([^"]+)"', window):
        items.append(("Reload Configuration", chord))
    return items


def main(argv):
    if not 2 <= len(argv) <= 3:
        raise SystemExit(f"usage: {argv[0]} <ghostty-src> [<packaging-dir>]")
    src = pathlib.Path(argv[1])
    defaults = pathlib.Path(
        argv[2] if len(argv) == 3 else pathlib.Path(__file__).resolve().parent
    ) / "defaults/herdr"

    problems = []
    for platform, collect, config, least in (
        ("macOS", macos_items, "config.toml", 30),
        ("Linux", linux_items, "config.linux.toml", 30),
    ):
        bound = herdr_chords(defaults / config)
        items = collect(src)
        if len(items) < least:
            problems.append(
                f"{platform}: found only {len(items)} menu chords; the parser "
                "stopped matching, so nothing was really checked"
            )
            continue
        for label, chord in items:
            if normalise(chord) not in bound:
                problems.append(
                    f"{platform}: menu item {label!r} sends {chord}, which "
                    f"defaults/herdr/{config} does not bind"
                )
        print(f"  {platform}: {len(items)} menu chords all bound by {config}")

    if problems:
        for line in problems:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
