import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
HELPER = PACKAGING / "helpers/mash-design-autostart"


class DesignAutostartTest(unittest.TestCase):
    """mash-design-autostart starts the stack only for an opted-in install.

    The opt-in is the marker file the startup wizard writes. Docker stopped must
    only log: the marker stays, so the next launch retries.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.data = self.home / ".mash"
        self.stack = self.data / "local/share/mash/design"
        self.bin = Path(self.tmp.name) / "app/bin"
        (self.stack / "bin").mkdir(parents=True)
        self.bin.mkdir(parents=True)
        (self.data / "setup").mkdir()
        (self.data / "config/mash").mkdir(parents=True)

        self.helper = self.bin / "mash-design-autostart"
        self.helper.write_bytes(HELPER.read_bytes())
        self.helper.chmod(0o755)

        self.docker = self.bin / "docker"
        self.set_docker(available=True)

        self.mds = self.stack / "bin/mds"
        self.write_mds(exit_code=0)

    def set_docker(self, available):
        self.docker.write_text("#!/bin/sh\nexit %d\n" % (0 if available else 1))
        self.docker.chmod(0o755)

    def write_mds(self, exit_code):
        self.mds.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> \"$MASH_DATA_DIR/setup/mds-invocations\"\n"
            "printf '%s\\n' \"$MASH_DESIGN_NONINTERACTIVE\" > \"$MASH_DATA_DIR/setup/noninteractive\"\n"
            f"exit {exit_code}\n"
        )
        self.mds.chmod(0o755)

    def enable(self):
        (self.data / "config/mash/design-autostart").write_text("1\n")

    def run_helper(self, data=None):
        return subprocess.run(
            [str(self.helper), str(data or self.data)],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )

    def log(self):
        path = self.data / "setup/design-autostart.log"
        return path.read_text() if path.exists() else ""

    def invocations(self):
        path = self.data / "setup/mds-invocations"
        return path.read_text() if path.exists() else ""

    def test_no_marker_does_nothing(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations(), "")
        self.assertEqual(self.log(), "")

    def test_docker_stopped_logs_and_retries_next_launch(self):
        self.enable()
        self.set_docker(available=False)
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations(), "")
        self.assertIn("Docker unavailable", self.log())
        self.assertTrue(
            (self.data / "config/mash/design-autostart").exists(),
            "the marker must survive so the next launch retries",
        )

    def test_starts_the_stack_when_enabled(self):
        self.enable()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations().strip(), "start")
        self.assertEqual((self.data / "setup/noninteractive").read_text().strip(), "1")
        self.assertIn("design stack started", self.log())

    def test_failed_start_is_logged_without_credentials(self):
        self.enable()
        self.write_mds(exit_code=1)
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed", self.log())
        # The CLI's own output stays private; only the outcome is recorded.
        combined = self.log() + result.stdout + result.stderr
        self.assertNotIn("PENPOT", combined)

    def test_missing_mds_is_reported(self):
        self.enable()
        self.mds.unlink()
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("mds is missing", self.log())

    def test_refuses_symlinked_marker(self):
        marker = self.data / "config/mash/design-autostart"
        outside = Path(self.tmp.name) / "outside"
        outside.write_text("1\n")
        marker.symlink_to(outside)
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.invocations(), "")
        self.assertIn("refusing a symlink", self.log())

    def test_running_account_setup_defers_without_compose_race(self):
        self.enable()
        lock = self.data / "setup/penpot-account-setup.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations(), "")
        self.assertIn("retry design stack next launch", self.log())

    def install_pane_entry(self, wizard_writes_marker):
        pane = self.bin / "herdr-pane"
        pane.write_bytes((PACKAGING / "herdr-pane").read_bytes())
        pane.chmod(0o755)
        (self.bin / "lib.sh").write_text(
            '#!/bin/bash\n'
            'mash_real_home() { printf "%s\\n" "$HOME"; }\n'
            'mash_mark_instance_window() { :; }\n'
            'mash_release_instance_window() { :; }\n'
            'mash_isolate() { export HERDR_SOCKET_PATH="$HOME/.mash/run/herdr.sock"; }\n'
        )
        wizard = self.bin / "mash-wizard"
        wizard.write_text(
            "#!/bin/sh\n"
            + ('touch "$HOME/.mash/config/mash/design-autostart"\n' if wizard_writes_marker else "")
            + "exit 0\n"
        )
        wizard.chmod(0o755)
        herdr = self.bin / "herdr"
        herdr.write_text("#!/bin/sh\nexit 0\n")
        herdr.chmod(0o755)
        account = self.bin / "mash-penpot-account-setup"
        account.write_text('#!/bin/sh\necho account >> "$HOME/.mash/setup/helper-runs"\n')
        account.chmod(0o755)
        return pane

    def test_wizard_opt_in_starts_on_first_launch_without_account_race(self):
        pane = self.install_pane_entry(wizard_writes_marker=True)
        (self.stack / "penpot.env").write_text("PENPOT_ACCESS_TOKEN=dummy\n")
        result = subprocess.run(
            [str(pane)],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "MASH_INSTANCE": "default"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for _ in range(100):
            if self.invocations():
                break
            time.sleep(0.02)
        self.assertEqual(self.invocations().strip(), "start")
        self.assertFalse((self.data / "setup/helper-runs").exists())

    def test_wizard_opt_out_preserves_account_setup_retry(self):
        pane = self.install_pane_entry(wizard_writes_marker=False)
        (self.stack / "penpot.env").write_text("PENPOT_ACCESS_TOKEN=\n")
        result = subprocess.run(
            [str(pane)],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin", "MASH_INSTANCE": "default"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for _ in range(100):
            if (self.data / "setup/helper-runs").exists():
                break
            time.sleep(0.02)
        self.assertEqual((self.data / "setup/helper-runs").read_text().strip(), "account")
        self.assertEqual(self.invocations(), "")

    def test_refuses_a_data_dir_outside_mash(self):
        outside = Path(self.tmp.name) / "elsewhere"
        outside.mkdir()
        result = self.run_helper(data=outside)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside ~/.mash", result.stderr)


if __name__ == "__main__":
    unittest.main()
