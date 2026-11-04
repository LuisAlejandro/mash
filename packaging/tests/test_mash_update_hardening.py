"""Safety contracts that do not launch an app, touch launchd, or need a DMG."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class UpdateHardeningTests(unittest.TestCase):
    def test_invalid_apply_arguments_fail_without_looping(self):
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "packaging/helpers/mash-update-apply"), "--dest"],
            capture_output=True, timeout=2,
        )
        self.assertEqual(result.returncode, 2)

    def test_apply_never_copies_after_quitting(self):
        apply = (ROOT / "packaging/helpers/mash-update-apply").read_text()
        self.assertNotIn('ditto "$staged"', apply)
        self.assertNotIn('printf \'%s\\n\' "$version" >"$data/local/state/update-success"', apply)
        self.assertIn("mash_update_confirm", apply)

    def test_jobs_are_never_replaced_to_start_an_update(self):
        verify = (ROOT / "packaging/helpers/mash-update-verify").read_text()
        self.assertNotIn('launchctl bootout "gui/$uid/app.mash.update"', verify)
        self.assertIn("mash_update_bootstrap", verify)

    def test_legacy_recovery_checks_liveness(self):
        notice = (ROOT / "packaging/helpers/mash-update-notice").read_text()
        self.assertIn("mash_update_legacy_active", notice)
        self.assertIn("mash_update_active", notice)


if __name__ == "__main__":
    unittest.main()
