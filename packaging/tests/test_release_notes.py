"""The GitHub release body must carry the version's HISTORY section.

`release_build_notes` in scripts/lib.sh renders that body. It used to anchor its
awk range on a line starting with the version, but gitchangelog writes markdown
headings ("## 1.2.3 (date)"), so the range never matched and every release body
shipped an empty "What's new" section that had to be pasted in by hand.
"""

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts" / "lib.sh"

HISTORY = """# Changelog


## 1.2.4 (2026-01-02)

### Fixed

* A later release. [Maintainer]


## 1.2.3 (2026-01-01)

### Fixed

* Finish a slow shutdown. [Maintainer]

### Added

* Something new. [Maintainer]


## 1.2.2 (2025-12-31)

### Fixed

* Older work. [Maintainer]
"""


class ReleaseNotesTest(unittest.TestCase):
    def release_build_notes(self, new_version="1.2.3"):
        """Run the real function against fixture files, with the print helpers stubbed."""
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "HISTORY.md").write_text(HISTORY)
            (pathlib.Path(tmp) / "RELEASE_DESCRIPTION.md").write_text("What Mash is.\n")
            script = (
                "set -euo pipefail\n"
                "print_step() { :; }\nprint_warning() { :; }\nprint_error() { :; }\n"
                f'source "{LIB}"\n'
                'git() { if [ "$1" = "config" ]; then echo "https://github.com/owner/repo.git"; return 0; fi; command git "$@"; }\n'
                "gh() { return 1; }\n"
                f'release_build_notes 1.2.2 {new_version}\n'
            )
            done = subprocess.run(
                ["bash", "-c", script], cwd=tmp, capture_output=True, text=True, timeout=60
            )
            self.assertEqual(done.returncode, 0, done.stderr)
            return done.stdout

    def test_notes_carry_the_markdown_section(self):
        notes = self.release_build_notes()
        self.assertIn("## What's new in 1.2.3", notes)
        self.assertIn("Finish a slow shutdown.", notes)
        self.assertIn("Something new.", notes)

    def test_notes_stop_at_the_next_version(self):
        notes = self.release_build_notes()
        self.assertNotIn("A later release.", notes)
        self.assertNotIn("Older work.", notes)
        self.assertIn("**Full Changelog**: https://github.com/owner/repo/compare/1.2.2...1.2.3", notes)

    def test_notes_keep_the_release_description(self):
        notes = self.release_build_notes()
        self.assertTrue(notes.startswith("What Mash is."), notes[:60])


if __name__ == "__main__":
    unittest.main()
