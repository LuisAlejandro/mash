"""Linux keybindings must not sit on a chord GNOME has already taken.

The failure this pins: GNOME grabs a keybinding in the compositor, before the
window exists in the key path, and mutter stops the event there
(src/core/keybindings.c returns CLUTTER_EVENT_STOP after running its handler).
No client-side Ghostty unbind can win that race. Four pane-focus actions were
bound to Ctrl+Alt+arrows -- GNOME's switch-to-workspace-* -- so pane focus was
unreachable by keyboard and the up/down pair silently did nothing; and
rename_workspace was on Ctrl+Alt+Shift+R, which is GNOME's screen recorder.

Nothing here needs the Ghostty checkout: the GNOME table below is the grab list
this repo has to stay off, and the tests read only files in this repository. The
menu-drift test is the one exception and skips when the fork is not around.
"""

import json
import re
import tomllib
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
DEFAULTS = PACKAGING / "defaults"

MOD_ALIASES = {
    "control": "ctrl",
    "ctrl": "ctrl",
    "primary": "ctrl",
    "alt": "alt",
    "meta": "alt",
    "mod1": "alt",
    "shift": "shift",
    "super": "super",
    "win": "super",
}
KEY_ALIASES = {
    "arrow_up": "up",
    "arrow_down": "down",
    "arrow_left": "left",
    "arrow_right": "right",
    "up": "up",
    "down": "down",
    "left": "left",
    "right": "right",
    "page_up": "pageup",
    "page_down": "pagedown",
    "backspace": "backspace",
    "esc": "escape",
    "return": "enter",
    # GTK writes bracket names both ways depending on the builder version.
    "bracketleft": "[",
    "bracket_left": "[",
    "bracketright": "]",
    "bracket_right": "]",
}


def chord(text):
    """Normalise TOML / GTK / Fresh spellings to (frozenset(mods), key)."""
    text = text.strip()
    if not text:
        return None
    mods, key = set(), None
    if "<" in text:
        for name in re.findall(r"<([A-Za-z_0-9]+)>", text):
            low = name.lower()
            if low in MOD_ALIASES:
                mods.add(MOD_ALIASES[low])
            else:
                key = KEY_ALIASES.get(low, low)
        rest = re.sub(r"<[A-Za-z_0-9]+>", "", text).strip()
        if rest:
            key = KEY_ALIASES.get(rest.lower(), rest.lower())
    else:
        for part in text.split("+"):
            low = part.strip().lower()
            if not low:
                continue
            if low in MOD_ALIASES:
                mods.add(MOD_ALIASES[low])
            else:
                key = KEY_ALIASES.get(low, low)
    if key is None:
        return None
    return frozenset(mods), key


def show(c):
    order = ("ctrl", "alt", "shift", "super")
    mods, key = c
    return "+".join([m for m in order if m in mods] + [key])


# Chords the GNOME session takes, with the schema key that takes them. Read from
# gsettings-desktop-schemas + gnome-shell upstream defaults; Ubuntu's own
# gsettings override adds none of these but does add show-desktop on ctrl+alt+d,
# so that one is listed too.
GNOME_GRABS = {
    "ctrl+alt+left": "wm.keybindings switch-to-workspace-left",
    "ctrl+alt+right": "wm.keybindings switch-to-workspace-right",
    "ctrl+alt+up": "wm.keybindings switch-to-workspace-up",
    "ctrl+alt+down": "wm.keybindings switch-to-workspace-down",
    "ctrl+alt+shift+left": "wm.keybindings move-to-workspace-left",
    "ctrl+alt+shift+right": "wm.keybindings move-to-workspace-right",
    "ctrl+alt+shift+up": "wm.keybindings move-to-workspace-up",
    "ctrl+alt+shift+down": "wm.keybindings move-to-workspace-down",
    "ctrl+alt+shift+r": "shell.keybindings show-screen-recording-ui",
    "ctrl+alt+d": "ubuntu-settings wm.keybindings show-desktop",
    "ctrl+alt+tab": "wm.keybindings switch-panels",
    "ctrl+alt+escape": "wm.keybindings cycle-panels",
}
GNOME_CHORDS = {chord(c): owner for c, owner in GNOME_GRABS.items()}


def herdr_linux():
    """Every chord the shipped Linux config binds, mapped to what binds it."""
    cfg = tomllib.loads((DEFAULTS / "herdr" / "config.linux.toml").read_text())
    keys = cfg.get("keys", {})
    bound = {}

    def add(spec, owner):
        values = spec if isinstance(spec, list) else [spec]
        for value in values:
            if not isinstance(value, str) or not value:
                continue
            for text in expand(value):
                if text.startswith("prefix+"):
                    continue          # needs the prefix key first
                c = chord(text)
                if c:
                    bound.setdefault(c, []).append(owner)

    for name, spec in keys.items():
        if name != "command":
            add(spec, name)
    for entry in keys.get("command", []):
        add(entry.get("key"), entry.get("description", "command"))
    return bound


def expand(spec):
    m = re.match(r"^(.*?)(\d)\.\.(\d)$", spec)
    if not m:
        return [spec]
    return [m.group(1) + str(i) for i in range(int(m.group(2)), int(m.group(3)) + 1)]


def fresh_linux():
    data = json.loads((DEFAULTS / "fresh" / "config.linux.json").read_text())
    bound = {}
    for entry in data.get("keybindings", []):
        if entry.get("action") == "unbind":
            continue
        text = "+".join(list(entry.get("modifiers", [])) + [entry.get("key", "")])
        c = chord(text)
        if c:
            bound.setdefault(c, []).append(entry.get("action"))
    return bound


def ghostty_linux_live():
    """Chords Mash's Linux Ghostty config still binds after its unbinds."""
    live, released = {}, set()
    for line in (DEFAULTS / "ghostty" / "config.linux").read_text().splitlines():
        m = re.match(r"^keybind\s*=\s*(?:performable:)?([^=]+)=(\S+)\s*$", line.strip())
        if not m:
            continue
        c = chord(m.group(1))
        if not c:
            continue
        if m.group(2) == "unbind":
            released.add(c)
        else:
            live.setdefault(c, []).append(m.group(2))
    return live, released


class GnomeGrabTest(unittest.TestCase):
    def test_herdr_avoids_every_gnome_chord(self):
        bound = herdr_linux()
        for c, owner in GNOME_CHORDS.items():
            if c in bound:
                self.fail(
                    f"herdr binds {show(c)} ({', '.join(bound[c])}) but GNOME takes it "
                    f"for {owner}; the key never reaches Mash. Move the action."
                )

    def test_fresh_avoids_every_gnome_chord(self):
        bound = fresh_linux()
        for c, owner in GNOME_CHORDS.items():
            if c in bound:
                self.fail(
                    f"Fresh binds {show(c)} ({', '.join(bound[c])}) but GNOME takes it "
                    f"for {owner}; the key never reaches the editor."
                )

    def test_mash_terminal_avoids_every_gnome_chord(self):
        live, _ = ghostty_linux_live()
        for c, owner in GNOME_CHORDS.items():
            if c in live:
                self.fail(
                    f"Mash Terminal binds {show(c)} ({', '.join(live[c])}) but GNOME "
                    f"takes it for {owner}."
                )


class GhosttyDefaultTest(unittest.TestCase):
    """Ghostty's own Linux defaults also consume a chord before herdr sees it.

    Both entries below come from the fork's src/config/Config.zig: the
    goto_split bindings (ctrl+alt+arrows) and the jump_to_prompt pair
    (ctrl+shift+arrows) are set with set.put, not set.putFlags, so they are not
    `performable:` and swallow the key unconditionally.
    """

    def test_ghostty_releases_the_chords_herdr_uses(self):
        _, released = ghostty_linux_live()
        for text in ("ctrl+shift+arrow_up", "ctrl+shift+arrow_down",
                     "ctrl+alt+arrow_left", "ctrl+alt+arrow_right"):
            with self.subTest(chord=text):
                self.assertIn(
                    chord(text),
                    released,
                    f"packaging/defaults/ghostty/config.linux must unbind {text}: "
                    "Ghostty's Linux default consumes it before herdr can.",
                )


class MovedChordTest(unittest.TestCase):
    """Regression pins for the two defects this test file was added for."""

    def test_pane_focus_is_not_on_a_gnome_arrow(self):
        cfg = tomllib.loads((DEFAULTS / "herdr" / "config.linux.toml").read_text())
        for name in ("focus_pane_left", "focus_pane_right",
                     "focus_pane_up", "focus_pane_down"):
            with self.subTest(action=name):
                value = cfg["keys"][name]
                self.assertTrue(value.startswith("ctrl+super+"), value)

    def test_rename_workspace_is_not_the_screen_recorder(self):
        cfg = tomllib.loads((DEFAULTS / "herdr" / "config.linux.toml").read_text())
        self.assertNotEqual(cfg["keys"]["rename_workspace"], "ctrl+alt+shift+r")

    def test_fresh_cursor_actions_are_not_on_herdr_chords(self):
        bound = herdr_linux()
        fresh = fresh_linux()
        for action in ("add_cursor_above", "add_cursor_below"):
            owners = [c for c, names in fresh.items() if action in names]
            self.assertEqual(len(owners), 1, action)
            self.assertNotIn(owners[0], bound, f"{action} sits on {show(owners[0])}")


class QuickrefTest(unittest.TestCase):
    """The reference card shipped into panes must match the configs."""

    def test_quickref_has_no_gnome_chord(self):
        text = (DEFAULTS / "pi" / "extensions" / "keybindings-quickref.linux.txt").read_text()
        token = re.compile(r"^\s+(Ctrl|Alt)((?:\+(?:Shift|Alt|Ctrl|Super))*)\+([A-Za-z0-9]+|\[|\]|\\|-|⌫)")
        seen = 0
        for line in text.splitlines():
            m = token.match(line)
            if not m:
                continue
            key = {"⌫": "backspace"}.get(m.group(3), m.group(3))
            c = chord(m.group(1) + m.group(2) + "+" + key)
            if c in GNOME_CHORDS:
                self.fail(
                    f"quickref lists {show(c)} but GNOME takes it for "
                    f"{GNOME_CHORDS[c]}"
                )
            seen += 1
        self.assertGreater(seen, 30, "the chord parser stopped matching the card")

    def test_quickref_does_not_claim_gnome_leaves_ctrl_alt_alone(self):
        text = (DEFAULTS / "pi" / "extensions" / "keybindings-quickref.linux.txt").read_text()
        self.assertNotIn("which GNOME leaves alone", text)


class MenuAcceleratorTest(unittest.TestCase):
    """The GTK menu is a second copy of herdr's chord table: it sends a fixed
    chord to the pty. Needs the Ghostty fork, so it skips without it."""

    def _blp(self):
        candidates = []
        if __import__("os").environ.get("MASH_GHOSTTY_SRC"):
            candidates.append(Path(__import__("os").environ["MASH_GHOSTTY_SRC"]))
        candidates.append(Path.home() / "Development" / "ghostty")
        for root in candidates:
            path = root / "src" / "apprt" / "gtk" / "ui" / "1.5" / "window.blp"
            if path.is_file():
                return path
        return None

    def test_every_menu_chord_is_one_herdr_binds(self):
        blp = self._blp()
        if blp is None:
            self.skipTest("Ghostty fork not available (set MASH_GHOSTTY_SRC)")
        text = blp.read_text()
        bound = herdr_linux()
        items = re.findall(
            r'label:\s*_\("([^"]+)"\);(.*?)(?=\n\s*label:|\Z)', text, re.S)
        checked = 0
        for label, body in items:
            if 'win.mash-send-key' not in body:
                continue                  # a real GTK action, not a chord replay
            target = re.search(r'target:\s*"([^"]+)"', body)
            if not target:
                continue
            c = chord(target.group(1))
            with self.subTest(item=label):
                self.assertIn(
                    c, bound,
                    f"menu item {label!r} sends {target.group(1)}, which herdr "
                    "does not bind any more",
                )
            checked += 1
        self.assertGreater(checked, 30, "the menu parser stopped matching the blp")


if __name__ == "__main__":
    unittest.main()
