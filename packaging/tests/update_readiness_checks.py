import plistlib
import shutil
import time
import unittest

from macos_update_fixture import UpdateFixture


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)
        self.id = self.f.begin()
        self.uuid = self.f.inspector("uuid", self.f.candidate / "Contents/MacOS/mash-terminal")
        # Atomic replacement is proven separately; install fixture's target.
        self.old = self.f.app.parent / "old.app"
        self.f.app.rename(self.old)
        shutil.copytree(self.f.candidate, self.f.app)
        self.f.change(phase="awaiting-ready", expected_uuid=self.uuid)
        server_bin = self.f.app / "Contents/Resources/bin/herdr"
        server_bin.parent.mkdir()
        shutil.copy(self.f.app / "Contents/MacOS/mash-terminal", server_bin)
        self.gui = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        self.socket = self.f.data / "run/herdr.sock"
        self.server = self.f.start(server_bin, "server", FIXTURE_SOCKET=str(self.socket))
        for _ in range(100):
            if self.socket.exists():
                break
            self.assertIsNone(self.server.poll())
            time.sleep(0.02)
        self.assertTrue(self.socket.exists())
        self.gui_ack = {"id": self.id, "version": "9.9.9", "uuid": self.uuid,
                        "pid": str(self.gui.pid), "start": self.f.inspector("stamp", self.gui.pid)}
        self.server_ack = {"id": self.id, "gui_pid": str(self.gui.pid),
                           "pid": str(self.server.pid), "start": self.f.inspector("stamp", self.server.pid)}

    def ack(self, gui=True, server=True):
        for kind, enabled, payload in (("gui", gui, self.gui_ack), ("server", server, self.server_ack)):
            if enabled:
                (self.f.data / f"local/state/update-{kind}-{self.id}.plist").write_bytes(plistlib.dumps(payload))

    def confirm(self):
        return self.f.shell(f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; MU_ID="{self.id}"; mash_update_confirm')

    def test_native_and_server_signals_are_both_required(self):
        self.assertNotEqual(self.confirm().returncode, 0)
        self.ack(server=False)
        self.assertNotEqual(self.confirm().returncode, 0)
        self.assertFalse((self.f.data / "local/state/update-success").exists())
        self.ack()
        result = self.confirm()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.state()["phase"], "confirmed")
        self.assertEqual((self.f.data / "local/state/update-success").read_text().strip(), "9.9.9")
        self.assertNotEqual(self.confirm().returncode, 0)  # consumed exactly once

    def test_wrong_image_version_attempt_or_pid_start_never_confirms(self):
        for key, value in (("uuid", "OLD-IMAGE"), ("version", "9.9.8"), ("id", "OLD-ATTEMPT"), ("start", "REUSED-PID")):
            with self.subTest(key=key):
                original = self.gui_ack[key]
                self.gui_ack[key] = value
                self.ack()
                self.assertNotEqual(self.confirm().returncode, 0)
                self.gui_ack[key] = original
        self.assertEqual(self.f.state()["phase"], "awaiting-ready")

    def test_dead_server_or_surviving_old_process_blocks_success(self):
        self.ack()
        previous = self.f.start(self.old / "Contents/MacOS/mash-terminal")
        (self.f.work / "old-processes").write_text(f"{previous.pid} {self.f.inspector('stamp', previous.pid)}\n")
        self.assertNotEqual(self.confirm().returncode, 0)
        previous.terminate()
        previous.wait(timeout=3)
        self.server.terminate()
        self.server.wait(timeout=3)
        self.assertNotEqual(self.confirm().returncode, 0)
        self.assertFalse((self.f.data / "local/state/update-success").exists())


if __name__ == "__main__":
    unittest.main()
