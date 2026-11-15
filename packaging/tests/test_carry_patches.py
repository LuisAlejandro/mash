#!/usr/bin/env python3
"""Every patch this repo applies to its own sources must still apply.

`carry.sh` applies `patches/herdr-workspace-absolute-path.patch` to the vendored
`packaging/plugins/herdr-workspace` tree at build time, and a rejected hunk
aborts the bundle build. Nothing checked that offline: a feature edited the same
function the patch is anchored on (#79, `apply_dir`), every test here passed,
and the release's Linux arm64 artifact build failed with "workspace patch did
not apply" -- after the release was cut and with the tag already pushed.

The Fresh and auto-title patches are not checked here: their sources are
fetched or vendored at build time, so a checkout cannot dry-run them. Their
failure mode is the same, and the guard extends the same way once a pinned
source is available locally.

Run with: python3 packaging/tests/test_carry_patches.py
"""

import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
PATCHES = PACKAGING / "patches"

# patch file -> the in-repo tree it is applied to, as carry.sh does it.
IN_REPO = {
    "herdr-workspace-absolute-path.patch": PACKAGING / "plugins" / "herdr-workspace",
}


def touched(diff_text: str) -> list[str]:
    """Paths a unified diff rewrites, in diff order."""
    return [
        match.group(1)
        for match in re.finditer(r"^\+\+\+ b/(\S+)", diff_text, re.M)
    ]


class CarryPatchTest(unittest.TestCase):
    def test_the_patches_carry_applies_to_its_own_sources_still_apply(self) -> None:
        self.assertTrue(IN_REPO, "no in-repo patch target is declared")
        for name, tree in IN_REPO.items():
            patch_file = PATCHES / name
            with self.subTest(patch=name):
                self.assertTrue(patch_file.is_file(), f"missing {patch_file}")
                self.assertTrue(tree.is_dir(), f"missing patch target {tree}")
                text = patch_file.read_text(encoding="utf-8")
                for path in touched(text):
                    self.assertTrue(
                        (tree / path).is_file(),
                        f"{name} rewrites {path}, which {tree.name} does not have",
                    )
                with tempfile.TemporaryDirectory() as raw:
                    copy = Path(raw) / tree.name
                    shutil.copytree(tree, copy, symlinks=True)
                    result = subprocess.run(
                        ["patch", "-p1", "--dry-run", "-d", str(copy)],
                        stdin=patch_file.open("rb"),
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        result.returncode,
                        0,
                        f"{name} no longer applies to {tree.name}; the build will "
                        f"abort. Re-anchor the patch:\n{result.stdout}{result.stderr}",
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
