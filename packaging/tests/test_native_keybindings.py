"""The Native keybinding mode: each tool's stock keys, Mash extras on Herdr's prefix.

Seeds a copy of the shipped defaults in both modes, for both platforms (the
seeder's MASH_SEED_PLATFORM override renders the other platform's files on one
host), and checks:

- Cursor-style output is unchanged apart from the one line Native added to
  Ghostty's config (`mash-keybindings = cursor`), so picking Native never alters
  the Cursor-style files;
- Native keeps every non-keybinding setting and drops every Mash keybinding;
- the Mash-extra prefix keys collide with nothing.

`herdr config check` rejects an unparseable key but says nothing about one that
shadows a stock binding (prefix+n is accepted as a custom command and silently
loses to next_tab), so the stock table below is the collision guard. Bump it
with Herdr's pin in packaging/assets.json.

Run with: python3 packaging/tests/test_native_keybindings.py
"""

import json
import os
import re
import runpy
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
REPO = PACKAGING.parent
DEFAULTS = PACKAGING / "defaults"
SYNC = PACKAGING / "helpers" / "mash-seed-sync"

# menu-chords.py is the single copy of Herdr 0.9.3's stock prefix table.
HERDR_STOCK_PREFIX_KEYS = {
    key: action for action, key in runpy.run_path(str(PACKAGING / "menu-chords.py"))["HERDR_STOCK"].items()
} | {str(n): "switch_tab" for n in range(1, 10)}
FILES = {
    "herdr": "config/herdr/config.toml",
    "ghostty": "config/ghostty/config",
    "fresh": "config/fresh/config.json",
    "pi": "pi/agent/keybindings.json",
    "quickref": "pi/agent/extensions/keybindings-quickref.txt",
}
PLATFORMS = ("Linux", "Darwin")


def seed(platform, mode):
    """Render the shipped defaults for one platform and mode; return {name: text|None}."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        res, data = tmp / "res", tmp / "data"
        shutil.copytree(DEFAULTS, res / "defaults", symlinks=True)
        (res / "defaults" / "optional-programming.txt").write_text("")
        shutil.copy(REPO / "VERSION", res / "VERSION")
        if mode == "native":
            (data / "setup").mkdir(parents=True)
            (data / "setup" / "keybindings-mode").write_text("mode=native\n")
        else:
            data.mkdir()
        proc = subprocess.run(
            [str(SYNC), str(res), str(data)],
            env={**os.environ, "MASH_SEED_PLATFORM": platform},
            capture_output=True, text=True, check=False,
        )
        assert proc.returncode == 0, proc.stderr
        out = {}
        for name, rel in FILES.items():
            path = data / rel
            # The temp root differs per run; normalise it so outputs compare.
            out[name] = path.read_text().replace(str(tmp), "<root>") if path.exists() else None
        return out


RENDERED = {(p, m): seed(p, m) for p in PLATFORMS for m in ("mash", "native")}


def herdr(platform, mode):
    return tomllib.loads(RENDERED[(platform, mode)]["herdr"])


class CursorStyleUnchangedTest(unittest.TestCase):
    def test_native_mode_only_adds_the_mode_line_to_cursor_style(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                cursor = RENDERED[(platform, "mash")]
                self.assertIn("mash-keybindings = cursor\n", cursor["ghostty"])
                # Everything else is the shipped source after path substitution.
                suffix = ".linux" if platform == "Linux" else ""
                source = (DEFAULTS / "ghostty" / f"config{suffix}").read_text()
                for line in source.splitlines():
                    if line.startswith("keybind"):
                        self.assertIn(line, cursor["ghostty"])
                fresh = json.loads(cursor["fresh"])
                shipped = json.loads((DEFAULTS / "fresh" / f"config{suffix}.json").read_text())
                self.assertEqual(fresh["keybindings"], shipped["keybindings"])
                self.assertEqual(cursor["pi"], (DEFAULTS / "pi" / "keybindings.json").read_text())
                sheet = "keybindings-quickref" + (".linux.txt" if platform == "Linux" else ".txt")
                self.assertEqual(cursor["quickref"], (DEFAULTS / "pi" / "extensions" / sheet).read_text())
                keys = herdr(platform, "mash")["keys"]
                self.assertEqual(keys["prefix"], "f24")


class NativeRenderingTest(unittest.TestCase):
    def test_herdr_keeps_every_non_key_setting(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                cursor, native = herdr(platform, "mash"), herdr(platform, "native")
                self.assertEqual(
                    {k: v for k, v in cursor.items() if k != "keys"},
                    {k: v for k, v in native.items() if k != "keys"},
                )

    def test_herdr_sets_no_stock_key_except_the_plugin_takeovers(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                keys = herdr(platform, "native")["keys"]
                self.assertEqual(
                    {k: v for k, v in keys.items() if k != "command"},
                    {"new_workspace": "", "new_worktree": ""},
                )

    def test_herdr_commands_keep_their_bodies(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                cursor = herdr(platform, "mash")["keys"]["command"]
                native = herdr(platform, "native")["keys"]["command"]
                strip = lambda cmds: [{k: v for k, v in c.items() if k != "key"} for c in cmds]
                self.assertEqual(strip(cursor), strip(native))

    def test_ghostty_has_no_mash_keybinds(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                cursor = RENDERED[(platform, "mash")]["ghostty"]
                native = RENDERED[(platform, "native")]["ghostty"]
                self.assertNotRegex(native, r"(?m)^\s*keybind\s*=")
                self.assertIn("mash-keybindings = native\n", native)
                strip = lambda text: [
                    l for l in text.splitlines()
                    if not re.match(r"\s*(keybind|mash-keybindings)\s*=", l)
                ]
                self.assertEqual(strip(cursor), strip(native))

    def test_fresh_uses_its_default_keymap(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                cursor = json.loads(RENDERED[(platform, "mash")]["fresh"])
                native = json.loads(RENDERED[(platform, "native")]["fresh"])
                self.assertNotIn("keybindings", native)
                self.assertNotIn("active_keybinding_map", native)
                cursor.pop("keybindings")
                self.assertEqual(cursor, native)

    def test_pi_keeps_its_own_keys(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                self.assertIsNone(RENDERED[(platform, "native")]["pi"])

    def test_pi_launcher_fallback_does_not_restore_native_override(self):
        # The normal launcher calls mash_seed_pi *after* the ownership seeder
        # on every launch. A seeder-only check misses this second copy path.
        for mode in ("mash", "native"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                res, data = Path(tmp) / "res", Path(tmp) / "data"
                shutil.copytree(DEFAULTS, res / "defaults", symlinks=True)
                (res / "defaults" / "optional-programming.txt").write_text("")
                shutil.copy(REPO / "VERSION", res / "VERSION")
                (data / "setup").mkdir(parents=True)
                if mode == "native":
                    (data / "setup" / "keybindings-mode").write_text("mode=native\n")
                for _ in range(2):
                    sync = subprocess.run(
                        [str(SYNC), str(res), str(data)], capture_output=True, text=True,
                    )
                    self.assertEqual(sync.returncode, 0, sync.stderr)
                    fallback = subprocess.run(
                        ["bash", "-c", '. "$1"; res="$2"; d="$3"; mash_seed_pi',
                         "bash", str(PACKAGING / "launch-common.sh"), str(res), str(data)],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(fallback.returncode, 0, fallback.stderr)
                    self.assertEqual(
                        (data / "pi/agent/keybindings.json").exists(), mode == "mash",
                    )

    def test_linux_sheet_names_the_intercepted_pi_keys(self):
        # Ghostty binds jump_to_prompt to ctrl+shift+arrow on Linux only
        # (Config.zig, the non-Darwin block), so Pi's stock Ctrl+Shift+Up/Down
        # never reach it in Native. Native ships Ghostty's stock keys, so the
        # sheet names Pi's working alternative instead of adding an unbind.
        sheet = RENDERED[("Linux", "native")]["quickref"]
        self.assertIn("Ctrl+\u2191 / Ctrl+\u2193", sheet)
        self.assertIn("Ctrl+Shift+\u2191/\u2193", sheet)
        # macOS binds super+shift+arrow there, so its sheet needs no caveat.
        self.assertNotIn("Ctrl+Shift+\u2191", RENDERED[("Darwin", "native")]["quickref"])

    def test_sheet_lists_native_keys_only(self):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                sheet = RENDERED[(platform, "native")]["quickref"]
                self.assertIn("Ctrl+B", sheet)
                self.assertNotIn("Ctrl+Alt+", sheet)
                self.assertNotIn("⌘", sheet)
                # Every Native extra key is on the sheet, written as the user types it.
                extras = sheet.split("── Mash extras")[1].split("── Fresh")[0]
                listed = {line.split()[0] for line in extras.splitlines()[1:] if line.strip()}
                spell = {"backtick": "`", "semicolon": ";"}
                for command in herdr(platform, "native")["keys"]["command"]:
                    bare = command["key"][len("prefix+"):]
                    shown = spell.get(bare, bare)
                    if shown.startswith("shift+"):
                        shown = "Shift+" + shown[len("shift+"):].upper()
                    self.assertIn(shown, listed, command["description"])


class NativeKeyTableTest(unittest.TestCase):
    def setUp(self):
        self.table = tomllib.loads((DEFAULTS / "herdr" / "keys.native.toml").read_text())

    def test_every_mash_extra_has_a_native_key(self):
        for name in ("config.toml", "config.linux.toml"):
            with self.subTest(source=name):
                descriptions = {
                    c["description"]
                    for c in tomllib.loads((DEFAULTS / "herdr" / name).read_text())["keys"]["command"]
                }
                self.assertEqual(descriptions, set(self.table["commands"]))

    def test_keys_are_prefix_keys_without_collisions(self):
        taken_over = {
            key for key, action in HERDR_STOCK_PREFIX_KEYS.items()
            if self.table["keys"].get(action) == ""
        }
        seen = {}
        for description, key in self.table["commands"].items():
            with self.subTest(command=description):
                self.assertTrue(key.startswith("prefix+"), key)
                bare = key[len("prefix+"):]
                if bare not in taken_over:
                    self.assertNotIn(bare, HERDR_STOCK_PREFIX_KEYS, f"{key} shadows Herdr's stock {HERDR_STOCK_PREFIX_KEYS.get(bare)}")
                self.assertNotIn(key, seen, f"{key} also used by {seen.get(key)}")
                seen[key] = description

    def test_takeovers_are_used_by_the_plugin(self):
        used = {key[len("prefix+"):] for key in self.table["commands"].values()}
        for action, value in self.table["keys"].items():
            with self.subTest(action=action):
                self.assertEqual(value, "")
                stock = [k for k, a in HERDR_STOCK_PREFIX_KEYS.items() if a == action]
                self.assertTrue(stock and set(stock) <= used, f"{action} unbound but its key is unused")

    @unittest.skipUnless(shutil.which("herdr"), "herdr is not installed")
    def test_herdr_accepts_both_modes(self):
        for platform in PLATFORMS:
            for mode in ("mash", "native"):
                with self.subTest(platform=platform, mode=mode), tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "config.toml"
                    path.write_text(RENDERED[(platform, mode)]["herdr"])
                    proc = subprocess.run(
                        ["herdr", "config", "check"],
                        env={**os.environ, "HERDR_CONFIG_PATH": str(path)},
                        capture_output=True, text=True, check=False,
                    )
                    self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
