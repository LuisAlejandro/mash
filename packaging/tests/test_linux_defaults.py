"""Contract tests for the Linux desktop defaults.

The macOS keymaps are Command-based and the notification story is an app
bundle; neither transfers. These tests assert the Linux variants keep the
product's action coverage while using chords and services the platform has, and
that no macOS-only binding leaks back in through a copy-paste edit.

Run with: python3 packaging/tests/test_linux_defaults.py
"""

import json
import re
import unittest
from pathlib import Path

import tomllib

PACKAGING = Path(__file__).resolve().parents[1]
DEFAULTS = PACKAGING / "defaults"

# A bare Ctrl+<letter> belongs to the shell or the editor: Ctrl+C interrupts,
# Ctrl+I is Tab, Ctrl+R searches history, Ctrl+U kills the line.
BARE_CTRL_LETTER = re.compile(r"^ctrl\+[a-z]$")


def load_herdr() -> dict:
    return tomllib.loads((DEFAULTS / "herdr" / "config.linux.toml").read_text())


def herdr_chords(config: dict) -> list[tuple[str, str]]:
    """Every chord with its owner: built-in actions and [[keys.command]] entries.

    Custom commands live in a list under keys.command rather than as scalar
    keys, so a scan of scalars alone misses them -- which is how five Linux
    chords once shipped bound to two commands each.
    """
    pairs = []
    for action, value in config.get("keys", {}).items():
        if action == "command":
            continue
        for chord in value if isinstance(value, list) else [value]:
            if isinstance(chord, str) and chord:
                pairs.append((action, chord))
    for command in config.get("keys", {}).get("command", []):
        keys = command.get("key", [])
        for chord in keys if isinstance(keys, list) else [keys]:
            if chord:
                pairs.append((command.get("description", "?"), chord))
    return pairs


class HerdrLinuxKeymapTest(unittest.TestCase):
    def setUp(self):
        self.config = load_herdr()

    def test_configuration_parses(self):
        self.assertIn("keys", self.config)

    def test_no_command_chords_remain(self):
        leaked = [c for _, c in herdr_chords(self.config) if "cmd+" in c]
        self.assertEqual([], leaked)

    def test_no_bare_ctrl_letter_chords(self):
        bare = [c for _, c in herdr_chords(self.config) if BARE_CTRL_LETTER.match(c)]
        self.assertEqual([], bare)

    def test_every_chord_is_unique(self):
        seen, duplicates = {}, []
        for action, chord in herdr_chords(self.config):
            if chord in seen:
                duplicates.append((chord, seen[chord], action))
            seen[chord] = action
        self.assertEqual([], duplicates)

    def test_native_notifications_are_enabled(self):
        # macOS sets "off" because its notifier app delivers instead. Linux has
        # no such app, so the Herdr/Ghostty route has to be on.
        self.assertEqual("system", self.config["ui"]["toast"]["delivery"])

    def test_pane_shell_is_substituted_at_seed_time(self):
        self.assertEqual("__MASH_SHELL__", self.config["terminal"]["default_shell"])

    def test_action_families_survive(self):
        # The point of the port is coverage, not chord identity: every family
        # the macOS config binds must still be reachable here.
        keys = self.config["keys"]
        for action in (
            "previous_tab",
            "next_tab",
            "close_pane",
            "split_vertical",
            "split_horizontal",
            "focus_pane_left",
            "focus_pane_right",
            "rename_workspace",
            "close_workspace",
            "toggle_sidebar",
            "zoom",
            "goto",
        ):
            with self.subTest(action=action):
                self.assertIn(action, keys)
                self.assertTrue(keys[action])


class GhosttyLinuxConfigTest(unittest.TestCase):
    def setUp(self):
        self.text = (DEFAULTS / "ghostty" / "config.linux").read_text()

    def test_identity_matches_the_packaged_app_id(self):
        # GNOME associates the window with the launcher through this value.
        self.assertRegex(self.text, r'(?m)^class\s*=\s*"app\.mash\.Mash"$')
        self.assertRegex(self.text, r'(?m)^x11-instance-name\s*=\s*"mash-terminal"$')

    def test_window_title_is_mash(self):
        self.assertRegex(self.text, r'(?m)^title\s*=\s*"Mash Terminal"$')

    def test_one_window_runs_as_a_single_instance(self):
        # Mash has one window. A second launch reaches the running instance
        # under Mash's own class and brings its window forward; the window's
        # program comes from `command`, since the launcher no longer passes -e.
        self.assertRegex(self.text, r"(?m)^gtk-single-instance\s*=\s*true$")
        self.assertRegex(self.text, r"(?m)^quit-after-last-window-closed\s*=\s*true$")
        self.assertRegex(self.text, r'(?m)^class\s*=\s*"app\.mash\.Mash"$')
        self.assertRegex(self.text, r"(?m)^command\s*=\s*__MASH_HERDR_PANE__$")
        launcher = (PACKAGING / "linux/launcher").read_text()
        # The exec line is exactly this: -e would force a new process per launch.
        self.assertRegex(launcher, r'(?m)^exec "\$res/bin/mash-terminal"$')

    def test_no_super_chords_are_released(self):
        # The macOS file unbinds Super chords because Command is Ghostty's
        # modifier there. On Linux Super belongs to the desktop session.
        self.assertNotIn("super+", self.text)

    def test_font_matches_the_packaged_font(self):
        self.assertRegex(self.text, r'(?m)^font-family\s*=\s*"MesloLGS NF"$')
        self.assertRegex(self.text, r'(?m)^font-size\s*=\s*10$')


class FreshLinuxKeymapTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((DEFAULTS / "fresh" / "config.linux.json").read_text())

    def test_no_command_modifier_remains(self):
        self.assertNotIn('"cmd"', json.dumps(self.data))

    def test_unbind_entries_are_dropped(self):
        # The macOS file unbinds Ctrl+X then binds Cmd+X, because the terminal
        # owned Ctrl. On Linux Ctrl is the editing modifier, so an unbind would
        # disable the binding it sits next to.
        unbinds = [b for b in self.data["keybindings"] if b.get("action") == "unbind"]
        self.assertEqual([], unbinds)

    def test_bindings_are_unique(self):
        seen, duplicates = set(), []
        for binding in self.data["keybindings"]:
            key = (binding["key"], tuple(binding.get("modifiers", [])), binding.get("when"))
            if key in seen:
                duplicates.append(key)
            seen.add(key)
        self.assertEqual([], duplicates)

    def test_editing_actions_survive(self):
        actions = {b["action"] for b in self.data["keybindings"]}
        for action in ("copy", "paste", "save", "undo"):
            with self.subTest(action=action):
                self.assertIn(action, actions)

    def test_language_tooling_configuration_is_untouched(self):
        # The keymap is the only part that differs; formatters and language
        # servers are shared with the macOS config.
        macos = json.loads((DEFAULTS / "fresh" / "config.json").read_text())
        self.assertEqual(macos["languages"], self.data["languages"])


class SeedSelectionTest(unittest.TestCase):
    """The launcher must pick the platform's keymaps, not the macOS ones."""

    def setUp(self):
        self.text = (PACKAGING / "launch-common.sh").read_text()

    def test_linux_variants_exist_for_every_platform_keymap(self):
        for path in ("herdr/config.linux.toml", "ghostty/config.linux", "fresh/config.linux.json"):
            with self.subTest(path=path):
                self.assertTrue((DEFAULTS / path).is_file(), f"{path} is missing")

    def test_seeding_switches_on_the_platform(self):
        self.assertIn('suffix=".linux"', self.text)
        self.assertIn('config${suffix}.toml', self.text)

    def test_the_cheat_sheet_lists_the_linux_chords(self):
        quickref = DEFAULTS / "pi/extensions/keybindings-quickref.linux.txt"
        self.assertTrue(quickref.is_file(), "the Linux cheat sheet is missing")
        text = quickref.read_text()
        self.assertNotIn("⌘", text)
        self.assertIn("Ctrl+Alt+", text)

    def test_fresh_variant_is_seeded_as_config_json(self):
        # Fresh reads config.json only, so a variant filename would be ignored.
        self.assertIn("config.linux.json", self.text)
        self.assertRegex(self.text, r"config/fresh/config\.json")


if __name__ == "__main__":
    unittest.main()
