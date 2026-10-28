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
import subprocess
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
        # Both platforms must actually have been compared, not parsed to zero.
        self.assertIn("macOS:", result.stdout)
        self.assertIn("Linux:", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
