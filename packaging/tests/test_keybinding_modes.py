"""The first-launch keybinding modes, as mash-seed-sync renders them.

Cursor-style is what Mash has always shipped. Native keeps Mash's Herdr
functions, Ghostty pass-through and Fresh capabilities, but drops Mash's
Cursor-style Fresh chords so Fresh's own keymap applies. The choice is recorded
by the wizard only when setup completes, so these tests drive the mode file
directly and assert the rendered bytes.

Run with: python3 packaging/tests/test_keybinding_modes.py
"""

import json
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
DEFAULTS = PACKAGING / "defaults"
SYNC = PACKAGING / "helpers" / "mash-seed-sync"
LINUX = platform.system() != "Darwin"
SUFFIX = ".linux" if LINUX else ""

# Kept in Native: Fresh's own keymaps never bind these actions, and the
# clipboards are the platform's editing convention.
NATIVE_KEEP = {
    "copy",
    "copy_file_path",
    "cut",
    "duplicateLineUp",
    "duplicate_line",
    "file_explorer_copy_full_path",
    "freshCloakToggleSetting",
    "paste",
    "save_all",
    "save_as",
    "select_all",
    "start_search_replace_in_buffer",
    "toggle_compose_mode",
}


class SeedFixture:
    """A resource root and data folder shaped like an installed Mash."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.res = self.root / "res"
        self.data = self.root / "data"
        self.record = self.data / "local" / "state" / "seeded.json"
        self.mode = self.data / "setup" / "keybindings-mode"
        self.fresh = self.data / "config" / "fresh" / "config.json"
        self.quickref = self.data / "pi" / "agent" / "extensions" / "keybindings-quickref.txt"
        self._build()

    def _build(self) -> None:
        (self.res / "defaults" / "fresh").mkdir(parents=True)
        (self.res / "defaults" / "pi" / "extensions").mkdir(parents=True)
        (self.res / "defaults" / "herdr").mkdir(parents=True)
        (self.res / "defaults" / "ghostty").mkdir(parents=True)
        (self.res / "VERSION").write_text("1.0.0\n")
        self.data.mkdir(parents=True)
        shutil.copy(
            DEFAULTS / "fresh" / f"config{SUFFIX}.json",
            self.res / "defaults" / "fresh" / f"config{SUFFIX}.json",
        )
        shutil.copy(
            DEFAULTS / "pi" / "extensions" / f"keybindings-quickref{SUFFIX}.txt",
            self.res / "defaults" / "pi" / "extensions" / f"keybindings-quickref{SUFFIX}.txt",
        )
        shutil.copy(
            DEFAULTS / "pi" / "extensions" / "keybindings-quickref.editor-native.txt",
            self.res / "defaults" / "pi" / "extensions" / "keybindings-quickref.editor-native.txt",
        )
        (self.res / "defaults" / "herdr" / f"config{SUFFIX}.toml").write_text(
            '[terminal]\ndefault_shell = "__MASH_SHELL__"\n'
        )
        (self.res / "defaults" / "ghostty" / f"config{SUFFIX}").write_text(
            "command = __MASH_HERDR_PANE__\n"
        )

    def set_mode(self, mode: str) -> None:
        self.mode.parent.mkdir(parents=True, exist_ok=True)
        self.mode.write_text(f"mode={mode}\n")

    def clear_mode(self) -> None:
        self.mode.unlink()

    def sync(self) -> str:
        proc = subprocess.run(
            [str(SYNC), str(self.res), str(self.data)],
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        return proc.stdout

    def shipped(self) -> dict:
        config = json.loads((DEFAULTS / "fresh" / f"config{SUFFIX}.json").read_text())
        config["check_for_updates"] = False
        config["self_update"] = False
        return config

    def installed(self) -> dict:
        return json.loads(self.fresh.read_text())

    def selection(self) -> dict:
        return json.loads(self.record.read_text())["selection"]

    def close(self) -> None:
        self._tmp.cleanup()


class KeybindingModeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = SeedFixture()

    def tearDown(self) -> None:
        self.fixture.close()

    def test_a_first_run_without_a_choice_is_cursor_style(self) -> None:
        self.fixture.sync()
        self.assertEqual(self.fixture.installed()["keybindings"], self.fixture.shipped()["keybindings"])
        self.assertEqual(self.fixture.selection()["keybindings"], "mash")

    def test_native_drops_cursor_style_chords_and_keeps_the_rest(self) -> None:
        self.fixture.set_mode("native")
        self.fixture.sync()
        installed = self.fixture.installed()
        shipped = self.fixture.shipped()["keybindings"]
        kept = installed["keybindings"]

        # Everything Mash adds beyond this set moves a stock action onto a
        # Cursor-style chord, so Native leaves Fresh's own map in charge.
        for entry in kept:
            self.assertIn(entry["action"], NATIVE_KEEP | {"unbind"})
            self.assertIn(entry, shipped)
        # Ghostty on macOS frees control characters for the terminal; a Fresh
        # unbind that disappeared would hand Ctrl+C back to Fresh's copy.
        self.assertEqual(
            [entry for entry in kept if entry["action"] == "unbind"],
            [entry for entry in shipped if entry["action"] == "unbind"],
        )
        self.assertEqual({entry["action"] for entry in kept} - {"unbind"}, NATIVE_KEEP)
        # Nothing outside the keymap is mode-dependent.
        self.assertEqual(
            {key: value for key, value in installed.items() if key != "keybindings"},
            {key: value for key, value in self.fixture.shipped().items() if key != "keybindings"},
        )

    def test_the_mode_is_part_of_the_record_so_a_retry_re_renders(self) -> None:
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "mash")
        self.fixture.set_mode("native")
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "native")
        self.assertEqual({entry["action"] for entry in self.fixture.installed()["keybindings"]} - {"unbind"}, NATIVE_KEEP)
        # Cancelling setup removes the choice, and the defaults come back.
        self.fixture.clear_mode()
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "mash")
        self.assertEqual(self.fixture.installed()["keybindings"], self.fixture.shipped()["keybindings"])

    def test_a_user_edit_after_native_seeding_is_kept(self) -> None:
        self.fixture.set_mode("native")
        self.fixture.sync()
        edited = self.fixture.installed()
        edited["keybindings"].append({"key": "q", "modifiers": ["alt"], "action": "unbind", "when": "normal"})
        self.fixture.fresh.write_text(json.dumps(edited, indent=2) + "\n")
        (self.fixture.res / "VERSION").write_text("1.1.0\n")
        self.fixture.sync()
        self.assertEqual(self.fixture.installed(), edited)

    def test_an_untouched_native_file_follows_a_later_release(self) -> None:
        self.fixture.set_mode("native")
        self.fixture.sync()
        shipped = json.loads((DEFAULTS / "fresh" / f"config{SUFFIX}.json").read_text())
        shipped["label"] = "next release"
        (self.fixture.res / "defaults" / "fresh" / f"config{SUFFIX}.json").write_text(
            json.dumps(shipped, indent=2) + "\n"
        )
        (self.fixture.res / "VERSION").write_text("1.1.0\n")
        self.fixture.sync()
        installed = self.fixture.installed()
        self.assertEqual(installed["label"], "next release")
        self.assertEqual({entry["action"] for entry in installed["keybindings"]} - {"unbind"}, NATIVE_KEEP)

    @unittest.skipIf(LINUX, "the Linux sheet lists no editor chords")
    def test_native_swaps_the_sheet_editor_block(self) -> None:
        self.fixture.sync()
        cursor_style = self.fixture.quickref.read_text()
        self.assertIn("── Editor ──", cursor_style)
        self.fixture.set_mode("native")
        self.fixture.sync()
        native = self.fixture.quickref.read_text()
        self.assertIn("── Editor (Fresh's own keys) ──", native)
        self.assertNotIn("── Editor ──", native)
        # The rest of the sheet is shared, so the mode changes one block only.
        self.assertTrue(native.startswith(cursor_style.split("── Editor")[0]))
        addendum = (DEFAULTS / "pi" / "extensions" / "keybindings-quickref.editor-native.txt").read_text()
        for line in addendum.splitlines():
            self.assertIn(line.strip(), native)
        # The block shares rows with the tail of the right column, which the
        # replacement must keep.
        for line in ("⌘⇧I        Help", "⌘U         Detach", "⌘B         Toggle sidebar"):
            self.assertIn(line, native)
        for dropped in ("Find / replace in files", "⌘⇧F", "⌘⇧E", "⌥⇧↓        Duplicate line"):
            self.assertNotIn(dropped, native)

    @unittest.skipIf(not LINUX, "the macOS sheet is the one with an editor block")
    def test_linux_sheet_is_mode_independent(self) -> None:
        self.fixture.sync()
        cursor_style = self.fixture.quickref.read_text()
        self.fixture.set_mode("native")
        self.fixture.sync()
        self.assertEqual(self.fixture.quickref.read_text(), cursor_style)


if __name__ == "__main__":
    unittest.main(verbosity=2)
