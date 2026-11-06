#!/usr/bin/env python3
"""The pinned Ghostty fork must ship every menu label in every language.

macOS reads Localizable.strings and Base.lproj/MainMenu.strings sheets; Linux
reads gettext catalogs, and only for locales listed in src/os/i18n_locales.zig.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = json.loads((ROOT / "packaging/i18n/languages.json").read_text())
EXPECTED = tuple(row["code"] for row in LANGUAGES)
STRINGS_KEY = re.compile(r'^"([^"]+)"\s*=', re.M)
MENU_KEY = re.compile(r'\.item\("(herdr\.menu\.item\.[a-z0-9_]+)"')
GTK_LABEL = re.compile(r'_\("([^"]+)"\)')
PO_ENTRY = re.compile(r'^msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"$', re.M)


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
        self.assertTrue((root / "Base.lproj/MainMenu.xib").is_file(), "strings load only over a Base.lproj nib")
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

    def test_every_gtk_menu_label_is_translated_for_the_locale_gettext_picks(self):
        locales = set(re.findall(r'^\s*"([^"]+)",', (self.fork / "src/os/i18n_locales.zig").read_text(), re.M))
        labels = set(GTK_LABEL.findall((self.fork / "src/apprt/gtk/ui/1.5/window.blp").read_text(encoding="utf-8")))
        self.assertGreater(len(labels), 40)
        for row in LANGUAGES:
            if row["code"] == "en":
                continue
            with self.subTest(language=row["code"]):
                # gettext tries ll_CC, then ll; the first one that ships wins.
                full = row["locale"].split(".")[0]
                picked = next((name for name in (full, full.split("_")[0]) if name in locales), None)
                self.assertIsNotNone(picked, f"no shipped gettext locale for {row['locale']}")
                po = (self.fork / f"po/{picked}.po").read_text(encoding="utf-8")
                translated = {msgid for msgid, msgstr in PO_ENTRY.findall(po) if msgstr}
                self.assertEqual(sorted(labels - translated), [], f"po/{picked}.po")


if __name__ == "__main__":
    unittest.main()
