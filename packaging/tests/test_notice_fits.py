#!/usr/bin/env python3
"""Translated update notices have to fit the popup herdr actually draws.

Herdr 0.9.3 sizes a popup by its outer cells, border included, then gives the
script (width - 3) columns and (height - 2) rows. See resolve_popup_geometry
in herdr's src/popup_size.rs at the v0.9.3 pin.
"""

from __future__ import annotations

import json
import re
import tomllib
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGING = ROOT / "packaging"
MESSAGES = PACKAGING / "i18n" / "messages" / "helpers"
TOML = PACKAGING / "plugins" / "mash-update-notice" / "herdr-plugin.toml"
HELPER = PACKAGING / "helpers" / "mash-update-notice"
PANE_SCRIPTS = (
    PACKAGING / "plugins" / "mash-update-notice" / "notice.sh",
    PACKAGING / "plugins" / "mash-update-notice" / "update.sh",
    PACKAGING / "plugins" / "mash-update-notice" / "updated.sh",
    PACKAGING / "plugins" / "image-popup" / "view.sh",
    HELPER,
)

CODES = (
    "bg", "cs", "de", "en", "es", "fr", "it", "ja", "ko", "pt-BR",
    "ru", "th", "uk", "vi", "zh-CN",
)

# Widest values those scripts substitute. "an older version" is the literal
# default when the installed version is empty; the URL is the one update.sh prints.
VERSION = "100.100.100"
OLDER = "an older version"
URL = "https://github.com/LuisAlejandro/mash/releases/latest"

NOTICE = {
    "plugin.mash-update-notice.pane.up-to-date-linux": {},
    "plugin.mash-update-notice.pane.up-to-date-macos": {"version": VERSION},
    "plugin.mash-update-notice.pane.restart-required": {
        "installed": VERSION,
        "candidate": VERSION,
    },
    "plugin.mash-update-notice.pane.previous-restored": {
        "installed": VERSION,
        "candidate": VERSION,
    },
    "plugin.mash-update-notice.pane.check-failed": {},
    "plugin.mash-update-notice.pane.apt-failed": {},
    "plugin.mash-update-notice.pane.available-linux": {
        "candidate": VERSION,
        "installed": OLDER,
    },
}
UPDATED = {
    "plugin.mash-update-notice.pane.updated": {"version": VERSION},
}
UPDATE = {
    "plugin.mash-update-notice.pane.update-unavailable": {
        "candidate": VERSION,
        "installed": OLDER,
        "url": URL,
    },
    "plugin.mash-update-notice.pane.update-accepted": {"candidate": VERSION},
    "plugin.mash-update-notice.pane.update-prompt": {
        "candidate": VERSION,
        "installed": OLDER,
    },
}
PANES = {"notice": NOTICE, "updated": UPDATED, "update": UPDATE}
UNBROKEN = ("sudo apt install --only-upgrade letsmash", URL)


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def wrapped_rows(text: str, width: int) -> int:
    """Rows a terminal uses, plus one when the last line fills the width.

    A line that ends in the last column moves the cursor onto the next row,
    which scrolls the first line out of a pane that was exactly full.
    """
    rows = 0
    last = 0
    for line in text.split("\n"):
        needed = display_width(line)
        if needed == 0:
            rows += 1
            last = 0
            continue
        rows += (needed + width - 1) // width
        last = needed % width or width
    if last == width:
        rows += 1
    return rows


def inner_cells(width: int, height: int) -> tuple[int, int]:
    pane_inner_width = width - 2
    columns = pane_inner_width if pane_inner_width <= 4 else pane_inner_width - 1
    return columns, height - 2


def fill(text: str, values: dict[str, str]) -> str:
    return re.sub(
        r"\{([A-Za-z_][A-Za-z0-9_]*)\}",
        lambda match: values.get(match.group(1), match.group(0)),
        text,
    )


def entry_text(catalog: dict, key: str) -> str:
    entry = catalog[key]
    if isinstance(entry, dict):
        entry = entry["text"]
    if not isinstance(entry, str):
        raise AssertionError(f"{key} is not text")
    return entry


def opener_sizes(source: str) -> dict[str, tuple[int, int]]:
    default = re.search(r"local width=(\d+) height=(\d+)", source)
    if default is None:
        raise AssertionError("mash-update-notice has no default popup size")
    sizes = {"notice": (int(default.group(1)), int(default.group(2)))}
    for name, width, height in re.findall(
        r"(updated|update)\)\s+width=(\d+)\s+height=(\d+)", source
    ):
        sizes[name] = (int(width), int(height))
    return sizes


class NoticeFitsTest(unittest.TestCase):
    def test_opener_uses_the_manifest_sizes(self):
        manifest = tomllib.loads(TOML.read_text(encoding="utf-8"))
        panes = {pane["id"]: pane for pane in manifest["panes"]}
        sizes = opener_sizes(HELPER.read_text(encoding="utf-8"))
        self.assertEqual(set(sizes), {"notice", "update", "updated"})
        for name, (width, height) in sizes.items():
            self.assertEqual((panes[name]["width"], panes[name]["height"]), (width, height), name)
        # The download pane was already tall enough; only the short notices grow.
        self.assertEqual(sizes["update"], (64, 16))
        self.assertGreaterEqual(sizes["notice"][1], 11)
        self.assertEqual(sizes["notice"][0], 56)

    def test_every_translation_fits_the_inner_pane(self):
        manifest = tomllib.loads(TOML.read_text(encoding="utf-8"))
        panes = {pane["id"]: pane for pane in manifest["panes"]}
        catalogs = {
            code: json.loads((MESSAGES / f"{code}.json").read_text(encoding="utf-8"))
            for code in CODES
        }
        for name, keys in PANES.items():
            columns, rows = inner_cells(panes[name]["width"], panes[name]["height"])
            for code, catalog in catalogs.items():
                for key, values in keys.items():
                    text = fill(entry_text(catalog, key), values)
                    used = wrapped_rows(text, columns)
                    self.assertLessEqual(
                        used, rows,
                        f"{code} {key} needs {used} rows in a {columns}x{rows} pane",
                    )
                    for line in text.split("\n"):
                        if any(token in line for token in UNBROKEN):
                            self.assertLessEqual(
                                display_width(line), columns,
                                f"{code} {key} wraps a command or URL",
                            )
        # updated.sh with no version prints only the dismiss hint.
        columns, rows = inner_cells(panes["updated"]["width"], panes["updated"]["height"])
        for code, catalog in catalogs.items():
            hint = "\n  " + entry_text(catalog, "helper.popup.dismiss")
            used = wrapped_rows(hint, columns)
            self.assertLessEqual(used, rows, f"{code} dismiss hint needs {used} rows")

    def test_english_fallbacks_match_the_catalog(self):
        english = json.loads((MESSAGES / "en.json").read_text(encoding="utf-8"))
        for path in PANE_SCRIPTS:
            source = path.read_text(encoding="utf-8")
            for key in re.findall(r"\bmash-t\s+((?:plugin|helper)\.\S+)", source):
                text = entry_text(english, key)
                encoded = text.replace("\\", "\\\\").replace("\n", "\\n")
                self.assertIn(
                    encoded, source,
                    f"{path.name} fallback for {key} is not the English catalog text",
                )


if __name__ == "__main__":
    unittest.main()
