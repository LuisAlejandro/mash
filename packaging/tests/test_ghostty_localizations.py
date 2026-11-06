#!/usr/bin/env python3
"""The pinned Ghostty fork must ship every macOS menu key in every language."""

from __future__ import annotations

import json
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = tuple(row["code"] for row in json.loads((ROOT / "packaging/i18n/languages.json").read_text()))
STRINGS_KEY = re.compile(r'^"([^"]+)"\s*=', re.M)
MENU_KEY = re.compile(r'\.item\("(herdr\.menu\.item\.[a-z0-9_]+)"')


def fork_root() -> Path | None:
    candidates = [os.environ.get("MASH_GHOSTTY_SRC", ""), str(ROOT.parent / "ghostty")]
    for candidate in candidates:
        path = Path(candidate) if candidate else None
        if path and (path / ".git").exists():
            return path
    return None


def string_keys(path: Path) -> set[str]:
    return set(STRINGS_KEY.findall(path.read_text(encoding="utf-8-sig")))


class GhosttyLocalizationsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fork = fork_root()
        if cls.fork is None:
            raise unittest.SkipTest("set MASH_GHOSTTY_SRC to the pinned fork checkout")
        cls.expected_commit = json.loads((ROOT / "packaging/assets.json").read_text())["components"]["ghostty"]["commit"]
        actual = subprocess.check_output(["git", "-C", str(cls.fork), "rev-parse", "HEAD"], text=True).strip()
        if actual != cls.expected_commit:
            raise unittest.SkipTest(f"fork checkout is {actual[:12]}, not pinned {cls.expected_commit[:12]}")

    def test_localizable_strings_have_the_same_keys_for_all_fifteen_languages(self):
        root = self.fork / "macos/Sources/App"
        expected_keys = string_keys(root / "en.lproj/Localizable.strings")
        self.assertTrue(expected_keys)
        for code in EXPECTED:
            with self.subTest(language=code):
                path = root / f"{code}.lproj/Localizable.strings"
                self.assertTrue(path.is_file(), f"missing {path}")
                self.assertEqual(string_keys(path), expected_keys)

    def test_main_menu_nib_localizations_have_the_same_keys(self):
        root = self.fork / "macos/Sources/App"
        # English is the Base-localized MainMenu.xib; Xcode generates its
        # English menu strings from that base, so no en.lproj/MainMenu.strings
        # is required. All other supported languages have explicit sheets.
        expected_keys = string_keys(root / "bg.lproj/MainMenu.strings")
        self.assertTrue(expected_keys)
        for code in EXPECTED:
            if code == "en":
                continue
            with self.subTest(language=code):
                path = root / f"{code}.lproj/MainMenu.strings"
                self.assertTrue(path.is_file(), f"missing {path}")
                self.assertEqual(string_keys(path), expected_keys)

    def test_every_mash_command_item_is_localized(self):
        root = self.fork / "macos/Sources/App"
        source = (root / "MashMenus.swift").read_text(encoding="utf-8")
        used = set(MENU_KEY.findall(source))
        self.assertGreater(len(used), 0)
        for code in EXPECTED:
            with self.subTest(language=code):
                available = string_keys(root / f"{code}.lproj/Localizable.strings")
                self.assertTrue(used <= available, f"{code} misses {sorted(used-available)}")


if __name__ == "__main__":
    unittest.main()
