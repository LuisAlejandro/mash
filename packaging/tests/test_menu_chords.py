"""Mash's menu items must send chords the shipped Herdr config still binds.

The menus live in the Ghostty fork and replay keystrokes; the bindings live
here. Nothing at runtime connects them, so a chord renamed on either side
leaves a menu item that does nothing and reports no error. The comparison
itself is packaging/menu-chords.py, which the build also runs through
mash_ghostty_trim_check; this drives it from the test suite.

Needs the fork. CI checks it out and sets MASH_GHOSTTY_SRC (see push.yml); a
developer without it gets a skip rather than a failure.

Run with: python3 packaging/tests/test_menu_chords.py
"""

import os
import shutil
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
CHECKER = PACKAGING / "menu-chords.py"


def fork_root():
    candidates = []
    if os.environ.get("MASH_GHOSTTY_SRC"):
        candidates.append(Path(os.environ["MASH_GHOSTTY_SRC"]))
    candidates.append(Path.home() / "Development" / "ghostty")
    candidates.append(PACKAGING.parents[1] / "ghostty")
    for root in candidates:
        if (root / "macos/Sources/App/MashMenus.swift").is_file():
            return root
    return None


class MenuChordTest(unittest.TestCase):
    def test_native_gtk_label_matches_its_target(self):
        root = fork_root()
        if root is None:
            self.skipTest("Ghostty fork not available (set MASH_GHOSTTY_SRC)")
        paths = (
            "macos/Sources/App/MashMenus.swift",
            "src/apprt/gtk/ui/1.5/window.blp",
            "src/apprt/gtk/class/window.zig",
        )
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp)
            for rel in paths:
                dest = copy / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / rel, dest)
            blueprint = copy / "src/apprt/gtk/ui/1.5/window.blp"
            text = blueprint.read_text()
            before = 'New Dev Tab  ·  Ctrl+B t'
            self.assertIn(before, text)
            blueprint.write_text(text.replace(before, 'New Dev Tab  ·  Ctrl+B z', 1))
            result = subprocess.run(
                [sys.executable, str(CHECKER), str(copy), str(PACKAGING)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("New Dev Tab", result.stderr)
            self.assertIn("label", result.stderr)

    def test_every_menu_chord_is_one_herdr_binds(self):
        root = fork_root()
        if root is None:
            self.skipTest("Ghostty fork not available (set MASH_GHOSTTY_SRC)")
        result = subprocess.run(
            [sys.executable, str(CHECKER), str(root), str(PACKAGING)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            0,
            result.returncode,
            f"menu chords drifted from the shipped Herdr config:\n"
            f"{result.stdout}{result.stderr}",
        )
        # Both platforms and both keybinding modes must actually have been
        # compared, not parsed to zero.
        for table in ("macOS cursor:", "macOS native:", "Linux cursor:", "Linux native:"):
            self.assertIn(table, result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
