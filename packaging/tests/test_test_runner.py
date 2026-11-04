"""Test result contracts using scratch runners and copied native safety suites."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE_SUITES = (
    "test_mash_update_checks.sh",
    "test_mash_update_apply.sh",
    "test_mash_update_handoff.sh",
    "test_mash_update_launch_gate.sh",
    "test_mash_update_lifecycle.sh",
    "test_mash_update_processes.sh",
    "test_mash_update_readiness.sh",
    "test_mash_update_review.sh",
    "test_mash_update_state.sh",
    "test_mash_update_verify.sh",
)


class TestRunnerContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mash-test-runner-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "dirname", "find", "sort", "mktemp", "rm"):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / "python3").symlink_to(sys.executable)
        for name in ("cargo", "node"):
            self.executable(self.bin / name, "exit 0\n")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(ROOT / "scripts/test.sh", scripts / "test.sh")
        for folder in ("packaging/tests", "packaging/helpers/tests"):
            (self.root / folder).mkdir(parents=True)
        for folder, name in (
            ("fork-from-message", "test_fork_from_message.py"),
            ("mash-orchestration", "test_orchestration.py"),
        ):
            path = self.root / "packaging/plugins" / folder / "tests" / name
            path.parent.mkdir(parents=True)
            path.write_text("pass\n")
        self.env = {"PATH": str(self.bin), "HOME": str(self.root / "home")}

    def executable(self, path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + source)
        path.chmod(0o755)

    def suite(self, name, source):
        path = self.root / "packaging/tests" / name
        path.write_text(source)
        return path

    def run_runner(self, **environment):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/test.sh")],
            env={**self.env, **environment}, capture_output=True, text=True, timeout=15,
        )

    def test_skip_is_visible_and_not_counted_as_executed(self):
        self.suite("test_pass.sh", "exit 0\n")
        self.suite("test_skip.sh", "echo 'SKIP: fixture unavailable'; exit 77\n")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SKIP  packaging/tests/test_skip.sh", result.stdout)
        self.assertNotIn("PASS  packaging/tests/test_skip.sh", result.stdout)
        self.assertIn("7 suite(s) ran", result.stdout)  # Six baseline suites plus pass.
        self.assertIn("1 skipped", result.stdout)

    def test_failures_survive_later_passes_and_skips(self):
        self.suite("test_00_fail.sh", "exit 78\n")
        self.suite("test_10_pass.sh", "exit 0\n")
        self.suite("test_20_skip.sh", "exit 77\n")
        result = self.run_runner()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL  packaging/tests/test_00_fail.sh", result.stdout)
        self.assertIn("PASS  packaging/tests/test_10_pass.sh", result.stdout)
        self.assertIn("SKIP  packaging/tests/test_20_skip.sh", result.stdout)
        self.assertIn("test: FAILED (8 suite(s) ran", result.stdout)

    def test_partial_skip_output_is_not_a_whole_suite_skip(self):
        self.suite("test_partial.sh", "echo 'SKIP: one optional check'; exit 0\n")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS  packaging/tests/test_partial.sh", result.stdout)
        self.assertIn("7 suite(s) ran", result.stdout)

    def test_applicable_patch_failure_stops_the_run(self):
        self.executable(self.root / "packaging/helpers/mash-ghostty-patch-menu", "exit 9\n")
        ghostty = self.root / "ghostty"
        ghostty.mkdir()
        result = self.run_runner(MASH_GHOSTTY_SRC=str(ghostty))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout + result.stderr)
        self.assertNotIn("test: PASSED", result.stdout)
        self.assertEqual(self.run_runner().returncode, 0)

    def test_missing_optional_runtimes_are_named_skips(self):
        (self.bin / "cargo").unlink()
        (self.bin / "node").unlink()
        self.suite("test_extension.mjs", "")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 suite(s) ran", result.stdout)
        self.assertIn("5 skipped", result.stdout)
        self.assertIn("SKIP  packaging/tests/test_extension.mjs", result.stdout)
        self.assertIn("cargo not installed", result.stdout)

    def test_unavailable_whole_suite_producers_return_77(self):
        self.executable(self.bin / "uname", "echo Linux\n")
        self.executable(self.bin / "node", "exit 1\n")
        shell_suites = (*NATIVE_SUITES, "test_fresh_pane_resume.sh",
                        "test_pi_restore_ownership.sh", "test_pi_project_dir.sh")
        for name in shell_suites:
            with self.subTest(suite=name):
                result = subprocess.run(
                    ["/bin/bash", str(ROOT / "packaging/tests" / name)],
                    env=self.env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        (self.bin / "cargo").unlink()
        preview = subprocess.run(
            [sys.executable, str(ROOT / "packaging/tests/test_wizard_preview.py")],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(preview.returncode, 77, preview.stdout + preview.stderr)

    @unittest.skipUnless(shutil.which("node"), "Node unavailable")
    def test_real_pi_conformance_without_a_pin_returns_77(self):
        result = subprocess.run(
            [shutil.which("node"), str(ROOT / "packaging/tests/test_wizard_pi_client.mjs")],
            env=self.env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "macOS native fixture unavailable")
class UpdaterSafetyAssertions(unittest.TestCase):
    def test_real_suite_rejects_forbidden_behavior_and_fixture_content(self):
        mutations = (
            (None, None),
            ("mash_update_write owner_start invalid\n", "mash_update_active() { return 0; }\n"),
            ('ln -s "$tmp/do-not-write" "$MU_TX"\n', "mash_update_begin() { return 0; }\n"),
            (None, 'label="app.mash.update"\n'),
            (None, "# /Applications/Mash.app\n"),
        )
        for index, (marker, injected) in enumerate(mutations):
            with self.subTest(mutation=index), tempfile.TemporaryDirectory(prefix="mash-state-assert-") as tmp:
                root = Path(tmp)
                tests = root / "packaging/tests"
                helpers = root / "packaging/helpers"
                tests.mkdir(parents=True)
                helpers.mkdir()
                for name in ("mash-update-common", "mash-update-processes.c"):
                    shutil.copy(ROOT / "packaging/helpers" / name, helpers / name)
                handoff = (ROOT / "packaging/tests/test_mash_update_handoff.sh").read_text()
                suite = (ROOT / "packaging/tests/test_mash_update_state.sh").read_text()
                if marker:
                    self.assertEqual(suite.count(marker), 1)
                    suite = suite.replace(marker, marker + injected, 1)
                elif injected:
                    handoff += injected
                (tests / "test_mash_update_handoff.sh").write_text(handoff)
                path = tests / "test_mash_update_state.sh"
                path.write_text(suite)
                result = subprocess.run(
                    ["/bin/bash", str(path)], env={**os.environ, "HOME": str(root)},
                    capture_output=True, text=True, timeout=30,
                )
                if index == 0:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("FAIL", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
