"""First-launch layout contract.

Mash starts with its final directories. No startup program converts or edits
earlier layouts. Hindsight's .local/bin, .hindsight and .pg0 are intentional.
"""

import json
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]


class FirstLaunchLayoutTest(unittest.TestCase):
    def test_launcher_and_build_use_the_first_launch_layout(self):
        self.assertFalse((PACKAGING / "helpers" / "mash-migrate-layout").exists())
        for path in (PACKAGING / "mash", PACKAGING / "build.sh"):
            self.assertNotIn("migrate-layout", path.read_text())

    def test_launcher_seeds_current_layout_and_preserves_hindsight_dirs(self):
        # Both launchers seed through launch-common.sh, so the layout lives
        # there; packaging/mash used to carry its own copy of this list.
        shared = (PACKAGING / "launch-common.sh").read_text()
        for launcher in ("mash", "linux/launcher"):
            with self.subTest(launcher=launcher):
                self.assertIn(
                    "mash_seed_all",
                    (PACKAGING / launcher).read_text(),
                    f"{launcher} must seed through the shared module",
                )
        for path in (
            '"$d/config/herdr"',
            '"$d/cache"',
            '"$d/pi/agent"',
            '"$d/setup"',
            '"$d/local/state"',
            '"$d/.local/bin"',
            '"$d/.hindsight"',
            '"$d/.pg0"',
        ):
            with self.subTest(path=path):
                self.assertIn(path, shared)

    def test_pi_settings_pins_match_the_manifest(self):
        settings = json.loads((PACKAGING / "defaults/pi/settings.json").read_text())
        manifest = json.loads((PACKAGING / "assets.json").read_text())
        pinned = {
            component["package"]: component["version"]
            for component in manifest["components"].values()
            if component.get("package") and component.get("version")
        }
        specs = [spec for spec in settings.get("packages", []) if str(spec).startswith("npm:")]
        self.assertTrue(specs)
        for spec in specs:
            name, _, version = str(spec)[len("npm:"):].rpartition("@")
            with self.subTest(spec=spec):
                self.assertIn(name, pinned)
                self.assertEqual(version, pinned[name])

    def test_pi_defaults_use_built_in_mcp(self):
        settings = json.loads((PACKAGING / "defaults/pi/settings.json").read_text())
        self.assertFalse(any("pi-mcp-adapter" in str(package) for package in settings.get("packages", [])))
        self.assertNotIn("-builtin:mcp", settings.get("extensions", []))


if __name__ == "__main__":
    unittest.main()
