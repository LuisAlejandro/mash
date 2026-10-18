import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MIGRATOR = Path(__file__).resolve().parents[1] / "helpers" / "mash-migrate-layout"


class LayoutMigrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / ".mash"
        self.root.mkdir()

    def migrate(self):
        return subprocess.run([sys.executable, str(MIGRATOR), str(self.root)], capture_output=True, text=True)

    def test_moves_data_and_repairs_embedded_paths(self):
        for name in (".config", ".cache", ".local", ".pi", ".setup"):
            (self.root / name).mkdir()
        config = self.root / ".config"
        pi = self.root / ".pi" / "agent"
        pi.mkdir()
        (pi / "auth.json").write_text("credentials stay untouched")
        (self.root / ".setup" / "state.txt").write_text("completed")
        (self.root / ".local" / "history.db").write_bytes(b"\x00history")
        (config / "herdr").mkdir()
        (config / "herdr" / "config.toml").write_text(f'config = "{config}/herdr"\n')
        (config / "pet").mkdir()
        (config / "pet" / "config.toml").write_text(f'snippetfile = "{config}/pet/snippet.toml"\n')
        (pi / "AGENTS.md").write_text("~/.mash/.pi/agent and ~/.mash/.config/mash\n")
        skill = pi / "skills" / "mash-parallel"
        skill.mkdir(parents=True)
        venv = config / "mash" / "venvs" / "mash-parallel"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin" / "pytest").write_text(f"#!{venv}/bin/python\n")
        (skill / ".venv").symlink_to(venv)

        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("config", "cache", "local", "pi", "setup"):
            self.assertTrue((self.root / name).is_dir())
            self.assertFalse((self.root / f".{name}").exists())
        self.assertEqual((self.root / "pi" / "agent" / "auth.json").read_text(), "credentials stay untouched")
        self.assertEqual((self.root / "setup" / "state.txt").read_text(), "completed")
        self.assertEqual((self.root / "local" / "history.db").read_bytes(), b"\x00history")
        self.assertIn("~/.mash/pi/agent", (self.root / "pi" / "agent" / "AGENTS.md").read_text())
        self.assertIn(str(self.root / "config"), (self.root / "config" / "herdr" / "config.toml").read_text())
        self.assertIn(str(self.root / "config"), (self.root / "config" / "pet" / "config.toml").read_text())
        self.assertIn(str(self.root / "config"), (self.root / "config" / "mash" / "venvs" / "mash-parallel" / "bin" / "pytest").read_text())
        self.assertEqual((self.root / "pi" / "agent" / "skills" / "mash-parallel" / ".venv").readlink(), self.root / "config" / "mash" / "venvs" / "mash-parallel")
        self.assertEqual(self.migrate().returncode, 0)

    def test_refuses_collisions_without_moving_anything(self):
        (self.root / ".config").mkdir()
        (self.root / "config").mkdir()
        (self.root / ".pi").mkdir()
        result = self.migrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("both", result.stderr)
        self.assertTrue((self.root / ".pi").is_dir())
        self.assertFalse((self.root / "pi").exists())

    def test_keeps_the_hindsight_shim_directory(self):
        """`.local/bin` is the shim home, not the old data directory.

        Mash's Hindsight shim lives in `$data/.local/bin` and the agent
        extension re-exports HOME to the data folder, so this directory is
        current and permanent. The launcher creates `local/` and the installer
        creates `.local/bin`, so a second launch used to find both and refuse to
        start — Mash was unopenable after the first wizard run.
        """
        (self.root / "local" / "state").mkdir(parents=True)
        shim = self.root / ".local" / "bin"
        shim.mkdir(parents=True)
        (shim / "hindsight-embed").write_text("#!/bin/sh\n")

        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((shim / "hindsight-embed").is_file())
        self.assertFalse((self.root / ".local" / "state").exists())
        self.assertTrue((self.root / "local" / "state").is_dir())
        # Idempotent: the next launch must not start refusing either.
        self.assertEqual(self.migrate().returncode, 0)

    def test_moves_an_old_local_directory_that_holds_more_than_the_shim(self):
        """A `.local` with anything besides `bin` is the old data directory."""
        (self.root / ".local" / "bin").mkdir(parents=True)
        (self.root / ".local" / "share").mkdir()
        (self.root / ".local" / "history.db").write_bytes(b"\x00history")

        result = self.migrate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / ".local").exists())
        self.assertEqual(
            (self.root / "local" / "history.db").read_bytes(), b"\x00history"
        )
        self.assertTrue((self.root / "local" / "bin").is_dir())

    def test_still_refuses_a_local_collision_with_real_data(self):
        (self.root / ".local" / "share").mkdir(parents=True)
        (self.root / "local").mkdir()
        result = self.migrate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("both", result.stderr)


class PiSettingsMigrationTest(unittest.TestCase):
    """The seeded settings must stop declaring the adapter Mash no longer ships."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / ".mash"
        (self.root / "pi" / "agent").mkdir(parents=True)
        self.settings = self.root / "pi" / "agent" / "settings.json"

    def migrate(self):
        return subprocess.run([sys.executable, str(MIGRATOR), str(self.root)], capture_output=True, text=True)

    def test_drops_adapter_and_builtin_mcp_exclusion(self):
        self.settings.write_text(
            json.dumps(
                {
                    "packages": ["npm:pi-subagents", "npm:pi-mcp-adapter", "npm:pi-ask-user"],
                    "extensions": ["-builtin:mcp"],
                    "theme": "Monokai Pro (CE)",
                }
            )
        )
        self.migrate()
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["packages"], ["npm:pi-subagents", "npm:pi-ask-user"])
        self.assertNotIn("extensions", data)
        self.assertEqual(data["theme"], "Monokai Pro (CE)")

    def test_keeps_other_extensions_and_is_idempotent(self):
        self.settings.write_text(
            json.dumps({"packages": [], "extensions": ["-builtin:mcp", "+builtin:codemode"]})
        )
        self.migrate()
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["extensions"], ["+builtin:codemode"])
        before = self.settings.read_bytes()
        self.migrate()
        self.assertEqual(self.settings.read_bytes(), before)

    def test_leaves_a_clean_settings_file_untouched(self):
        original = json.dumps({"packages": ["npm:pi-subagents"], "lastChangelogVersion": "1.1.0"})
        self.settings.write_text(original)
        self.migrate()
        self.assertEqual(self.settings.read_text(), original)


if __name__ == "__main__":
    unittest.main()
