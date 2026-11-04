"""Fault-injection regressions for review findings 1-8. No real app or job."""
import os
import pathlib
import plistlib
import shutil
import subprocess
import time
import unittest

from macos_update_fixture import ROOT, UpdateFixture


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)

    def common(self, code):
        return self.f.shell(f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; MU_ID="{self.f.state()["id"]}"; {code}')

    def test_1_handoff_keeps_a_delayed_worker_owned(self):
        self.f.begin()
        self.f.change(phase="handoff", owner_start="dead-verifier", handoff_deadline=int(self.f.inspector("now")) + 60)
        self.assertEqual(self.common("mash_update_active").returncode, 0)
        self.assertNotEqual(self.common(f'mash_update_begin "{self.f.app}" 9.9.9 9.9.8 "{self.f.work}"').returncode, 0)
        self.f.change(handoff_deadline=int(self.f.inspector("now")) - 1)
        self.assertNotEqual(self.common("mash_update_active").returncode, 0)

    def test_2_same_uuid_does_not_make_different_releases_equal(self):
        self.f.begin()
        uuid = self.f.inspector("uuid", self.f.app / "Contents/MacOS/mash-terminal")
        self.assertEqual(self.common(f'mash_update_bundle_is "{self.f.app}" 9.9.8 {uuid}').returncode, 0)
        self.assertNotEqual(self.common(f'mash_update_bundle_is "{self.f.app}" 9.9.9 {uuid}').returncode, 0)
        self.f.change(phase="swap-intent", owner_start="dead-owner", expected_uuid=uuid, old_uuid=uuid)
        self.assertEqual(self.common("mash_update_reconcile").returncode, 0)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")

    def test_3_registered_setup_survives_exec_and_waiter_is_excluded(self):
        self.f.begin()
        process = self.f.start("/bin/sleep", "30")
        tool = str(self.f.bin / "mash-update-processes")
        for role in ("setup", "waiter", "runtime"):
            with self.subTest(role=role):
                registered = subprocess.run([tool, "register", str(self.f.data), str(self.f.app), str(process.pid), role], capture_output=True, text=True)
                self.assertEqual(registered.returncode, 0, registered.stderr)
                rows = self.f.inspector("list", self.f.app, self.f.data).splitlines()
                included = any(row.split()[0] == str(process.pid) for row in rows)
                self.assertEqual(included, role != "waiter")

    def test_5_recovery_coordinator_stops_hung_target_then_retries(self):
        attempt = self.f.begin()
        sibling = self.f.app.parent / ".mash-update-ABCDEF"
        sibling.mkdir()
        shutil.copytree(self.f.app, sibling / "Mash.app")
        (sibling / ".mash-update-owner").write_text(attempt + "\n")
        server_bin = self.f.app / "Contents/Resources/bin/herdr"
        server_bin.parent.mkdir(exist_ok=True)
        shutil.copy(self.f.app / "Contents/MacOS/mash-terminal", server_bin)
        failed = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        failed_stamp = self.f.inspector("stamp", failed.pid)
        self.f.change(phase="recovery-required", sibling=sibling, old_version="9.9.8",
                      old_uuid=self.f.inspector("uuid", sibling / "Mash.app/Contents/MacOS/mash-terminal"),
                      expected_team="TEAM", installed=1, candidate="9.9.9",
                      expected_uuid=self.f.inspector("uuid", self.f.app / "Contents/MacOS/mash-terminal"))
        self.f.stub("osascript", f'''echo "osascript $*" >>"$CALLS"
case "$*" in
*"display dialog"*) echo "Retry startup" ;;
*"tell application"*) "{self.f.bin}/mash-update-processes" term {failed.pid} {failed_stamp} ;;
esac''')
        process = subprocess.Popen(["/bin/bash", str(self.f.bin / "mash-update-gate"), "recover-owned", str(self.f.app), str(self.f.data), attempt], env=self.f.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        acked = False
        try:
            deadline = time.monotonic() + 30
            while process.poll() is None and time.monotonic() < deadline:
                failed.poll()
                current = self.f.state()
                if current["phase"] == "awaiting-ready" and not acked:
                    acked = True
                    self.assertIsNotNone(failed.poll(), "recovery started while the failed GUI was alive")
                    gui = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
                    socket = self.f.data / "run/herdr.sock"
                    server = self.f.start(self.f.app / "Contents/Resources/bin/herdr", "server", FIXTURE_SOCKET=str(socket))
                    for _ in range(100):
                        if socket.exists():
                            break
                        time.sleep(0.02)
                    for kind, payload in (("gui", {"id": attempt, "pid": str(gui.pid), "start": self.f.inspector("stamp", gui.pid), "version": current["candidate"], "uuid": current["expected_uuid"]}),
                                          ("server", {"id": attempt, "gui_pid": str(gui.pid), "pid": str(server.pid), "start": self.f.inspector("stamp", server.pid)})):
                        (self.f.data / f"local/state/update-{kind}-{attempt}.plist").write_bytes(plistlib.dumps(payload))
                time.sleep(.05)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertTrue(acked)
            self.assertEqual(self.f.state()["phase"], "confirmed")
            self.assertFalse(sibling.exists())
            self.assertNotIn("KILL", self.f.calls.read_text())
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)

    def test_5_recovery_stops_the_attempted_gui_before_restart(self):
        self.f.begin()
        process = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        stamp = self.f.inspector("stamp", process.pid)
        self.f.stub("osascript", f'"{self.f.bin}/mash-update-processes" term {process.pid} {stamp}')
        result = self.common(f'mash_update_quiesce "{self.f.app}" "{self.f.work}/failed-runtime"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(process.poll())
        self.assertNotIn("KILL", self.f.calls.read_text())

    def test_6_all_readiness_participants_use_the_attempt_deadline(self):
        self.f.begin()
        self.f.change(readiness_deadline=int(self.f.inspector("now")) + 100)
        result = self.common("mash_update_remaining")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(int(result.stdout.strip()), 90)
        gate = (ROOT / "packaging/helpers/mash-update-gate").read_text()
        self.assertNotIn("seq 1 150", gate)
        self.assertIn("mash_update_remaining", gate)
        self.assertIn("mash_update_run", gate)

    def test_7_manual_check_distinguishes_running_and_installed(self):
        resources = self.f.app / "Contents/Resources"
        (resources / "VERSION").write_text("9.9.9\n")
        bin_dir = resources / "bin"
        bin_dir.mkdir()
        for name in ("mash-update-common", "mash-update-processes"):
            shutil.copy(self.f.bin / name, bin_dir / name)
        self.f.stub("curl", 'printf \'{"tag_name":"9.9.9"}\\n\'')
        self.f.stub("sleep", ":")
        herdr = bin_dir / "herdr"
        herdr.write_text('#!/bin/bash\ncase "$1 $2" in\n"status server") echo "status: running" ;;\n"plugin pane") printf "%s\\n" "$*" >>"$CALLS" ;;\nesac\n')
        herdr.chmod(0o700)
        result = subprocess.run(["/bin/bash", str(ROOT / "packaging/helpers/mash-update-notice"), "--manual", str(resources), str(self.f.data)], env={**self.f.env, "MASH_RUNNING_VERSION": "9.9.8"}, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.f.calls.read_text()
        self.assertIn("MASH_UPDATE_STATUS=restart-required", calls)
        self.assertIn("MASH_UPDATE_INSTALLED=9.9.8", calls)
        self.assertNotIn("MASH_UPDATE_STATUS=up-to-date", calls)

    def test_8_waiting_gui_launch_has_a_visible_status_surface(self):
        attempt = self.f.begin()
        self.f.change(phase="quiescing", owner_pid=os.getpid(), owner_start=self.f.inspector("stamp", os.getpid()))
        marker = self.f.root / "launch-marker"
        process = subprocess.Popen(["/bin/bash", str(self.f.bin / "mash-update-gate"), "wait", str(self.f.app), str(self.f.data), attempt], env={**self.f.env, "FIXTURE_LAUNCH_MARKER": str(marker)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and "Updating Mash" not in self.f.calls.read_text():
                time.sleep(.05)
            self.assertIn("Updating Mash", self.f.calls.read_text())
            self.f.change(phase="failed-before-swap")
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
