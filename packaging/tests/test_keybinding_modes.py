"""The first-launch keybinding modes, as mash-seed-sync renders them.

Cursor-style is what Mash has always shipped. Native leaves Fresh on its own
default keymap with no Mash entries at all. The Herdr, Ghostty, Pi and sheet
sides of Native are covered by test_native_keybindings.py. The choice is recorded
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
        # carry.sh stages this inventory into every bundle beside the defaults.
        (self.res / "defaults" / "optional-programming.txt").write_text("")
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
            DEFAULTS / "pi" / "extensions" / f"keybindings-quickref.native{SUFFIX}.txt",
            self.res / "defaults" / "pi" / "extensions" / f"keybindings-quickref.native{SUFFIX}.txt",
        )
        shutil.copy(DEFAULTS / "herdr" / "keys.native.toml", self.res / "defaults" / "herdr" / "keys.native.toml")
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

    def test_native_leaves_fresh_on_its_own_keymap(self) -> None:
        self.fixture.set_mode("native")
        self.fixture.sync()
        installed = self.fixture.installed()
        self.assertNotIn("keybindings", installed)
        # Nothing outside the keymap is mode-dependent.
        shipped = self.fixture.shipped()
        shipped.pop("keybindings")
        self.assertEqual(installed, shipped)

    def test_the_mode_is_part_of_the_record_so_a_retry_re_renders(self) -> None:
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "mash")
        self.fixture.set_mode("native")
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "native")
        self.assertNotIn("keybindings", self.fixture.installed())
        # Cancelling setup removes the choice, and the defaults come back.
        self.fixture.clear_mode()
        self.fixture.sync()
        self.assertEqual(self.fixture.selection()["keybindings"], "mash")
        self.assertEqual(self.fixture.installed()["keybindings"], self.fixture.shipped()["keybindings"])

    def test_a_user_edit_after_native_seeding_is_kept(self) -> None:
        self.fixture.set_mode("native")
        self.fixture.sync()
        edited = self.fixture.installed()
        edited["keybindings"] = [{"key": "q", "modifiers": ["alt"], "action": "unbind", "when": "normal"}]
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
        self.assertNotIn("keybindings", installed)

    def test_native_seeds_its_own_sheet(self) -> None:
        self.fixture.sync()
        cursor_style = self.fixture.quickref.read_text()
        self.fixture.set_mode("native")
        self.fixture.sync()
        native = self.fixture.quickref.read_text()
        self.assertNotEqual(native, cursor_style)
        self.assertEqual(
            native,
            (DEFAULTS / "pi" / "extensions" / f"keybindings-quickref.native{SUFFIX}.txt").read_text(),
        )

if __name__ == "__main__":
    unittest.main(verbosity=2)
