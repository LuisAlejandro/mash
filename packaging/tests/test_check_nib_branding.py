#!/usr/bin/env python3
"""check-nib-branding.py reads localized sheets in every encoding Xcode ships.

The source .strings files are UTF-8, but a built bundle carries UTF-16 with a
byte-order mark or a binary property list. A check that only reads UTF-8 fails
on every real build, which is why each encoding is exercised here.
"""

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECK = Path(__file__).resolve().parents[1] / "check-nib-branding.py"


def sheet(encoding, pairs):
    if encoding == "bplist":
        return plistlib.dumps(dict(pairs), fmt=plistlib.FMT_BINARY)
    text = "".join(f'"{key}" = "{value}";\n' for key, value in pairs)
    if encoding == "utf-16":
        return text.encode("utf-16")  # Python writes the byte-order mark
    return text.encode("utf-8")


class CheckNibBrandingTest(unittest.TestCase):
    def run_check(self, encoding, pairs):
        with tempfile.TemporaryDirectory() as tmp:
            lproj = Path(tmp) / "Contents" / "Resources" / "es.lproj"
            lproj.mkdir(parents=True)
            (lproj / "MainMenu.strings").write_bytes(sheet(encoding, pairs))
            return subprocess.run(
                [sys.executable, str(CHECK), tmp], capture_output=True, text=True
            )

    def test_every_encoding_passes_without_the_old_name(self):
        for encoding in ("utf-8", "utf-16", "bplist"):
            with self.subTest(encoding=encoding):
                result = self.run_check(encoding, [("Quit Mash", "Salir de Mash")])
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_every_encoding_fails_on_the_old_name(self):
        for encoding in ("utf-8", "utf-16", "bplist"):
            with self.subTest(encoding=encoding):
                result = self.run_check(encoding, [("About Ghostty", "Acerca de Ghostty")])
                self.assertNotEqual(0, result.returncode, result.stdout)
                self.assertIn("still says Ghostty", result.stderr)

    def test_base_localized_nib_is_checked(self):
        # The menu nib lives in Base.lproj so AppKit applies the .strings.
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / "Contents" / "Resources" / "Base.lproj"
            base.mkdir(parents=True)
            text = b"About Ghostty"  # a nib inline string: 0x08, 0x80+length
            (base / "MainMenu.nib").write_bytes(bytes([8, 0x80 + len(text)]) + text)
            result = subprocess.run(
                [sys.executable, str(CHECK), tmp], capture_output=True, text=True
            )
        self.assertNotEqual(0, result.returncode, result.stdout)
        self.assertIn("MainMenu.nib: still says Ghostty", result.stderr)


if __name__ == "__main__":
    unittest.main()
