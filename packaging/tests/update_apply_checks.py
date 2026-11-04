import pathlib
import shutil
import subprocess
import unittest

from macos_update_fixture import UpdateFixture


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)
        self.id = self.f.begin()
        self.sibling = self.f.app.parent / ".mash-update-ABCDEF"
        self.sibling.mkdir()
        self.prepared = self.sibling / "Mash.app"
        shutil.copytree(self.f.candidate, self.prepared)
        for name in ("mash-update-common", "mash-update-gate", "mash-update-processes", "mash-update-swap", "mash-update-apply"):
            shutil.copy(self.f.bin / name, self.f.work / name)
        self.f.change(phase="ready", sibling=self.sibling,
                      expected_uuid=self.f.inspector("uuid", self.prepared / "Contents/MacOS/mash-terminal"))
        self.args = ["/bin/bash", str(self.f.work / "mash-update-apply"), "--app", str(self.prepared), "--dest", str(self.f.app), "--data", str(self.f.data), "--work", str(self.f.work), "--version", "9.9.9", "--attempt", self.id]

    def apply(self, **extra):
        return subprocess.run(self.args, env={**self.f.env, **extra}, text=True, capture_output=True, timeout=20)

    def test_swap_failure_keeps_previous_app(self):
        swap = self.f.work / "mash-update-swap"
        swap.write_text("#!/bin/bash\nexit 1\n")
        swap.chmod(0o700)
        result = self.apply()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
        self.assertFalse((self.f.data / "local/state/update-success").exists())

    def test_launch_failure_retains_old_bundle_and_helpers(self):
        result = self.apply(FAKE_OPEN_RC="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.f.state()["phase"], "recovery-required")
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.9")
        self.assertEqual((self.prepared / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
        self.assertTrue((self.f.work / "mash-update-processes").exists())
        self.assertFalse((self.f.data / "local/state/update-success").exists())
        self.assertNotIn("ditto ", self.f.calls.read_text())

    def test_quit_refusal_does_not_replace_or_kill_gui(self):
        child = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        result = self.apply(FAKE_QUIT_RC="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIsNone(child.poll())
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")

    def test_foreign_attempt_is_rejected_before_shutdown(self):
        self.args[-1] = "not-this-attempt"
        result = self.apply()
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("quit ", self.f.calls.read_text())
        self.assertEqual(self.f.state()["phase"], "ready")


if __name__ == "__main__":
    unittest.main()
