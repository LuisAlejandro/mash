"""Verifier acceptance, rejection, ordering, cancellation and handoff."""
import pathlib
import plistlib
import unittest

from macos_update_fixture import UpdateFixture


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)
        (self.f.data / "local/state/update-notice").write_text("9.9.9\n")

    def test_prepared_candidate_is_final_and_job_is_attempt_scoped(self):
        result = self.f.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = self.f.state()
        self.assertEqual(state["phase"], "ready")
        self.assertTrue(pathlib.Path(state["sibling"], "Mash.app/Contents/MacOS/mash-terminal").exists())
        job = plistlib.loads(pathlib.Path(state["work"], "update-job.plist").read_bytes())
        self.assertEqual(job["Label"], "app.mash.update." + state["id"])
        self.assertIn("--attempt", job["ProgramArguments"])
        self.assertEqual(self.f.calls.read_text().count("ditto "), 1)
        self.assertNotIn("bootout", self.f.calls.read_text())
        self.assertNotIn("quit ", self.f.calls.read_text())
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
        self.assertIn("Prepared", self.f.data.joinpath("local/state/mash-update.log").read_text().title())

    def test_cancellation_cleans_only_preparation(self):
        result = self.f.verify("n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.state()["phase"], "cancelled")
        self.assertNotIn("bootstrap", self.f.calls.read_text())
        self.assertFalse(list(self.f.app.parent.glob(".mash-update-*")))
        self.assertTrue((self.f.data / "local/state/update-notice").exists())

    def test_trust_and_preparation_failures_leave_old_app(self):
        for setting in ("FAKE_TEAM", "FAKE_CODESIGN_RC", "FAKE_SPCTL_RC", "FAKE_DOWNLOAD_RC", "FAKE_MOUNT_RC", "FAKE_COPY_RC", "FAKE_DETACH_RC", "FAKE_BOOTSTRAP_RC"):
            with self.subTest(setting=setting):
                result = self.f.verify(**{setting: "FOREIGN" if setting == "FAKE_TEAM" else "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.f.state()["phase"], "failed-before-swap")
                self.assertNotIn("quit ", self.f.calls.read_text())
                self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
                self.assertFalse(list(self.f.app.parent.glob(".mash-update-*")))

    def test_wrong_version_or_bundle_identity_is_rejected(self):
        for key, value in (("CFBundleIdentifier", "other.app"), ("CFBundleShortVersionString", "0.0.0"), ("CFBundleVersion", "0.0.0")):
            with self.subTest(key=key):
                path = self.f.candidate / "Contents/Info.plist"
                original = path.read_bytes()
                metadata = plistlib.loads(original)
                metadata[key] = value
                path.write_bytes(plistlib.dumps(metadata))
                result = self.f.verify()
                path.write_bytes(original)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.f.state()["phase"], "failed-before-swap")
                self.assertNotIn("bootstrap", self.f.calls.read_text())
        (self.f.candidate / "Contents/Resources/VERSION").write_text("0.0.0\n")
        self.assertNotEqual(self.f.verify().returncode, 0)

    def test_live_legacy_job_is_not_stopped(self):
        self.f.stub("launchctl", 'echo "launchctl $*" >>"$CALLS"; case "$1" in print) echo "    pid = 12345" ;; esac')
        result = self.f.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootout", self.f.calls.read_text())
        self.assertNotIn("curl ", self.f.calls.read_text())


if __name__ == "__main__":
    unittest.main()
