#!/usr/bin/env python3
"""Check that every Mash menu item sends a chord Herdr actually binds.

Mash's menus do not call Herdr. Each item replays the keystroke a user would
type, through the `mash_send_key` binding action, so an item only works while
its chord is still the one the shipped Herdr config binds. Nothing else
connects the two: the menu tables live in the Ghostty fork, the bindings live
in this repository, and a chord renamed on one side leaves an item that opens a
menu, does nothing, and reports no error.

Both platforms and both keybinding modes are checked from their own sources:

  macOS  macos/Sources/App/MashMenus.swift  vs  defaults/herdr/config.toml
  Linux  src/apprt/gtk/ui/1.5/window.blp    vs  defaults/herdr/config.linux.toml

For each, the Cursor-style table (MashMenus' plain tables, window.blp's
`main_menu`) is checked against that config, and the Native table (the
`native*` tables, `main_menu_native`) against Herdr's stock keymap plus
defaults/herdr/keys.native.toml. Native items send a prefix sequence such as
`ctrl+b>n`.

The check also runs the other way: every chord a keymap binds must have a menu
item in that mode on that platform, or an entry in NOT_IN_MENU saying why not.
Without it a new binding silently never reaches the menus.

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
    "comma": ",",
    "semicolon": ";",
    "slash": "/",
    "backtick": "`",
    "backquote": "`",
}
# Herdr writes Command as `cmd`; Ghostty accepts `cmd` as an alias for `super`.
MOD_ALIASES = {"super": "cmd", "command": "cmd", "option": "alt", "control": "ctrl"}


# Shifted punctuation Herdr names by its character: Ghostty sends the US-layout
# key with Shift, and Herdr matches it by the shifted codepoint.
SHIFTED = {"/": "?", ";": ":"}


def normalise(chord):
    if ">" in chord:
        return ">".join(normalise(part) for part in chord.split(">"))
    parts = []
    for part in chord.strip().lower().split("+"):
        part = MOD_ALIASES.get(part, part)
        parts.append(KEY_ALIASES.get(part, part))
    mods = sorted(p for p in parts if p in ("cmd", "ctrl", "alt", "shift"))
    keys = [p for p in parts if p not in ("cmd", "ctrl", "alt", "shift")]
    if "shift" in mods and len(keys) == 1 and keys[0] in SHIFTED:
        mods.remove("shift")
        keys = [SHIFTED[keys[0]]]
    return "+".join(mods + keys)


def herdr_chords(path):
    """Every chord the shipped Herdr config binds, built-in actions and commands."""
    keys = tomllib.loads(path.read_text(encoding="utf-8")).get("keys", {})
    found = set()
    for name, value in keys.items():
        if name == "command":
            continue
        for chord in value if isinstance(value, list) else [value]:
            # "cmd+ctrl+1..9" is a range, not a chord an item can send, and the
            # indexed selectors (tab, workspace and agent by number) are
            # deliberately keyboard-only: nine menu items per family would bury
            # the actions that have no other route. Skipping the range here is
            # what exempts them from the coverage check below.
            if isinstance(chord, str) and chord and ".." not in chord:
                found.add(normalise(chord))
    for command in keys.get("command", []):
        chords = command.get("key", [])
        for chord in chords if isinstance(chords, list) else [chords]:
            if chord and ".." not in chord:
                found.add(normalise(chord))
    return found


# herdr 0.9.3, KeysConfig::default: stock prefix keys by action. The Native
# collision test imports this table rather than maintaining another copy.
HERDR_PREFIX = "ctrl+b"
HERDR_STOCK = {
    "help": "?", "settings": "s", "new_workspace": "shift+n", "new_worktree": "shift+g",
    "rename_workspace": "shift+w", "close_workspace": "shift+d", "workspace_picker": "w",
    "goto": "g", "detach": "q", "reload_config": "shift+r", "open_notification_target": "o",
    "new_tab": "c", "rename_tab": "shift+t", "previous_tab": "p", "next_tab": "n",
    "close_tab": "shift+x", "rename_pane": "shift+p", "edit_scrollback": "e", "copy_mode": "[",
    "focus_pane_left": "h", "focus_pane_down": "j", "focus_pane_up": "k", "focus_pane_right": "l",
    "swap_pane_left": "shift+h", "swap_pane_down": "shift+j", "swap_pane_up": "shift+k",
    "swap_pane_right": "shift+l", "cycle_pane_next": "tab", "cycle_pane_previous": "shift+tab",
    "split_vertical": "v", "split_horizontal": "minus", "close_pane": "x", "zoom": "z",
    "resize_mode": "r", "toggle_sidebar": "b",
}


def native_display(chord):
    """Show a Herdr prefix sequence in the GTK Native menu's label: the key as
    typed, lowercase plain and uppercase shifted, e.g. "Ctrl+B t", "Ctrl+B T",
    "Ctrl+B {", "Ctrl+B Ctrl+K", "Ctrl+B Shift+Tab"."""
    prefix, key = chord.split(">", 1)
    if prefix != HERDR_PREFIX:
        return None
    parts = key.split("+")
    mods, key = parts[:-1], parts[-1]
    shifted_char = {"slash": "?", "bracket_left": "{", "bracket_right": "}"}
    named = {"tab": "Tab", "backspace": "Backspace", "arrow_up": "Up", "arrow_down": "Down",
             "arrow_left": "Left", "arrow_right": "Right"}
    punct = {"minus": "-", "semicolon": ";", "backtick": "`", "backquote": "`",
             "bracket_left": "[", "bracket_right": "]"}
    if mods == ["shift"] and key in shifted_char:
        return "Ctrl+B " + shifted_char[key]
    if mods == ["shift"] and len(key) == 1:
        return "Ctrl+B " + key.upper()
    name = named.get(key) or punct.get(key) or (key.upper() if mods else key)
    return "Ctrl+B " + "".join(m.capitalize() + "+" for m in mods) + name


def native_chords(path):
    """Every sequence the Native Herdr keymap binds: stock keys, minus the ones
    keys.native.toml unbinds, plus the keys it gives unbound actions and its
    Mash commands."""
    native = tomllib.loads(path.read_text(encoding="utf-8"))
    found = set()
    for action, key in HERDR_STOCK.items():
        if native["keys"].get(action) != "":
            found.add(normalise(f"{HERDR_PREFIX}>{key}"))
    # Actions Herdr leaves unbound, given a prefix key by keys.native.toml.
    for key in list(native["keys"].values()) + list(native["commands"].values()):
        if not key:
            continue
        found.add(normalise(key.replace("prefix+", HERDR_PREFIX + ">", 1)))
    return found


def macos_items(src):
    """(label, chord) for every macOS menu entry and the three app-menu chords."""
    text = (src / "macos/Sources/App/MashMenus.swift").read_text(encoding="utf-8")
    tables = {"cursor": [], "native": []}
    for name, body in re.findall(r"static let (\w+): \[Entry\] = \[(.*?)\n    \]", text, re.S):
        mode = "native" if name.startswith("native") else "cursor"
        tables[mode] += re.findall(
            r'\.item\("herdr\.menu\.item\.[a-z0-9_]+",\s*"([^"]+)",\s*"([^"]+)"\)',
            body,
        )
    for name, native, cursor in re.findall(
        r'static var (\w+)Chord: String \{ native \? "([^"]+)" : "([^"]+)" \}', text
    ):
        tables["cursor"].append((name, cursor))
        tables["native"].append((name, native))
    return tables


def linux_items(src):
    """(label, chord) for every GTK menu item that replays a chord."""
    text = (src / "src/apprt/gtk/ui/1.5/window.blp").read_text(encoding="utf-8")
    tables = {"cursor": [], "native": []}
    reload_labels = {}
    for name, menu in re.findall(r"^menu (\w+) \{(.*?)^\}", text, re.S | re.M):
        mode = "native" if name.endswith("_native") else "cursor"
        reload_labels[mode] = re.findall(
            r'label:\s*_\("([^"]+)"\);\s*action:\s*"win.mash-reload"', menu
        )
        for label, body in re.findall(
            r'label:\s*_\("([^"]+)"\);(.*?)(?=\n\s*label:|\Z)', menu, re.S
        ):
            if "win.mash-send-key" not in body:
                continue  # a real GTK action, not a chord replay
            target = re.search(r'target:\s*"([^"]+)"', body)
            if target:
                tables[mode].append((label, target.group(1)))
    # Reload is a Zig action that sends Herdr's chord itself, per mode.
    window = (src / "src/apprt/gtk/class/window.zig").read_text(encoding="utf-8")
    for native, cursor in re.findall(
        r'mash_send_key = if \(native\) "([^"]+)" else "([^"]+)"', window
    ):
        for mode, chord in (("cursor", cursor), ("native", native)):
            if len(reload_labels.get(mode, [])) != 1:
                raise ValueError(f"{mode} menu has no unique Reload Configuration label")
            tables[mode].append((reload_labels[mode][0], chord))
    return tables


# Bound chords that deliberately have no menu item of their own, with why. Every
# other chord a keymap binds must appear in that mode's menu on both platforms,
# so a new binding fails here until someone decides where it belongs.
NOT_IN_MENU = {
    "cursor": {
        normalise("f24"): "the neutered prefix key, not an action",
        normalise("cmd+shift+n"): "synonym of New Dev Tab (cmd+t)",
        normalise("cmd+alt+n"): "synonym of New Agent Tab (cmd+alt+t)",
        normalise("ctrl+shift+n"): "synonym of New Dev Tab (ctrl+alt+t)",
        normalise("ctrl+alt+n"): "synonym of New Agent Tab (ctrl+alt+shift+t)",
        # Reopen has no menu item of its own: the fork's menus carry the launchers
        # and the close actions, and a new item means new localization keys there.
        # The chord works either way, so it stays chord-only until one is added.
        normalise("cmd+shift+t"): "reopen closed tab; chord-only, no menu item yet",
        normalise("ctrl+shift+t"): "reopen closed tab; chord-only, no menu item yet",
    },
    "native": {
        normalise("ctrl+b>c"): "stock new tab; the dev-tab plugin shapes it into New Dev Tab",
        normalise("ctrl+b>w"): "Herdr's own picker; the menu's Workspace Picker is the sesh plugin",
        normalise("ctrl+b>ctrl+t"): "reopen closed tab; chord-only, no menu item yet",
    },
}


def main(argv):
    if not 2 <= len(argv) <= 3:
        raise SystemExit(f"usage: {argv[0]} <ghostty-src> [<packaging-dir>]")
    src = pathlib.Path(argv[1])
    defaults = pathlib.Path(
        argv[2] if len(argv) == 3 else pathlib.Path(__file__).resolve().parent
    ) / "defaults/herdr"

    problems = []
    native = native_chords(defaults / "keys.native.toml")
    for platform, collect, config in (
        ("macOS", macos_items, "config.toml"),
        ("Linux", linux_items, "config.linux.toml"),
    ):
        tables = collect(src)
        for mode, bound, source in (
            ("cursor", herdr_chords(defaults / config), config),
            ("native", native, "the Native keymap"),
        ):
            items = tables[mode]
            shown = {normalise(chord) for _, chord in items}
            for chord in sorted(bound - shown - set(NOT_IN_MENU[mode])):
                problems.append(
                    f"{platform} {mode}: {source} binds {chord}, which no menu item "
                    "sends; add an item or list it in NOT_IN_MENU"
                )
            if len(items) < 30:
                problems.append(
                    f"{platform} {mode}: found only {len(items)} menu chords; the "
                    "parser stopped matching, so nothing was really checked"
                )
                continue
            for label, chord in items:
                if normalise(chord) not in bound:
                    problems.append(
                        f"{platform} {mode}: menu item {label!r} sends {chord}, "
                        f"which {source} does not bind"
                    )
                if platform == "Linux" and mode == "native":
                    shown = native_display(chord)
                    if shown is None or not label.endswith("  ·  " + shown):
                        problems.append(
                            f"{platform} {mode}: menu label {label!r} does not show "
                            f"target {chord} as {shown!r}"
                        )
            print(f"  {platform} {mode}: {len(items)} menu chords all bound by {source}")

    if problems:
        for line in problems:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
