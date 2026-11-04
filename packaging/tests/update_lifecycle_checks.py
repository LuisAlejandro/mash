import pathlib
import plistlib
import shutil
import subprocess
import time
import unittest

from macos_update_fixture import UpdateFixture


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)

    def test_prepare_shutdown_exchange_readiness_cleanup_chain(self):
        server_bin = self.f.candidate / "Contents/Resources/bin/herdr"
        server_bin.parent.mkdir()
        shutil.copy(self.f.candidate / "Contents/MacOS/mash-terminal", server_bin)
        user_file = self.f.data / "workspaces/project/notes.txt"
        user_file.parent.mkdir(parents=True)
        user_file.write_bytes(b"user-owned work, not updater state\n")
        before = user_file.read_bytes()
        previous = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        previous_start = self.f.inspector("stamp", previous.pid)
        self.f.stub("osascript", f'''echo "osascript $*" >>"$CALLS"
case "$*" in
*"tell application"*) "{self.f.bin}/mash-update-processes" term {previous.pid} {previous_start} ;;
*) : ;;
esac''')
        prepared = self.f.verify()
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        self.assertIsNone(previous.poll(), "preparation must leave the current app running")
        state = self.f.state()
        job = plistlib.loads(pathlib.Path(state["work"], "update-job.plist").read_bytes())
        worker = subprocess.Popen(job["ProgramArguments"], env=self.f.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: worker.poll() is None and worker.terminate())
        target_started = False
        try:
            deadline = time.monotonic() + 20
            while worker.poll() is None and time.monotonic() < deadline:
                previous.poll()  # reap fixture GUI, including its zombie PID
                current = self.f.state()
                if current["phase"] == "awaiting-ready" and not target_started:
                    target_started = True
                    self.assertIsNotNone(previous.poll())
                    gui = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
                    socket = self.f.data / "run/herdr.sock"
                    server = self.f.start(self.f.app / "Contents/Resources/bin/herdr", "server", FIXTURE_SOCKET=str(socket))
                    for _ in range(100):
                        if socket.exists():
                            break
                        time.sleep(0.02)
                    self.assertTrue(socket.exists())
                    gui_ack = {"id": state["id"], "pid": str(gui.pid), "start": self.f.inspector("stamp", gui.pid),
                               "version": "9.9.9", "uuid": state["expected_uuid"]}
                    server_ack = {"id": state["id"], "gui_pid": str(gui.pid), "pid": str(server.pid),
                                  "start": self.f.inspector("stamp", server.pid)}
                    for kind, payload in (("gui", gui_ack), ("server", server_ack)):
                        (self.f.data / f"local/state/update-{kind}-{state['id']}.plist").write_bytes(plistlib.dumps(payload))
                time.sleep(0.04)
            self.assertIsNotNone(worker.poll(), "fixture worker did not complete")
            out, err = worker.communicate(timeout=3)
            self.assertEqual(worker.returncode, 0, out + err + "\nstate=" + str(self.f.state()) + "\nlog=" + (self.f.data / "local/state/mash-update.log").read_text()[-5000:])
            self.assertTrue(target_started)
            self.assertEqual(self.f.state()["phase"], "confirmed")
            self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.9")
            self.assertFalse(pathlib.Path(state["sibling"]).exists())
            self.assertFalse(pathlib.Path(state["work"]).exists())
            self.assertEqual(user_file.read_bytes(), before)
            log = (self.f.data / "local/state/mash-update.log").read_text()
            for phase in ("preparing", "ready", "quiescing", "swap-intent", "awaiting-ready", "confirmed"):
                self.assertIn("phase=" + phase, log)
            self.assertIsNone(gui.poll())
            self.assertIsNone(server.poll())
        finally:
            if worker.poll() is None:
                worker.terminate()
                worker.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
