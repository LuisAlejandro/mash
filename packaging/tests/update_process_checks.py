import os
import signal
import subprocess
import time
import unittest

from macos_update_fixture import UpdateFixture


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)

    def test_snapshot_keeps_system_interpreter_descendants(self):
        parent = self.f.start(self.f.app / "Contents/MacOS/mash-terminal", "child")
        rows = {}
        for _ in range(50):
            rows = dict(line.split() for line in self.f.inspector("list", self.f.app).splitlines())
            if len(rows) >= 2:
                break
            time.sleep(0.05)
        self.assertIn(str(parent.pid), rows)
        descendants = {pid: stamp for pid, stamp in rows.items() if pid != str(parent.pid)}
        self.assertTrue(descendants)
        try:
            parent.terminate()
            parent.wait(timeout=3)
            # Saved identities still identify orphaned system /bin/sleep.
            for pid, stamp in descendants.items():
                self.assertEqual(self.f.inspector("image", pid), "/bin/sleep")
                result = subprocess.run([str(self.f.bin / "mash-update-processes"), "alive", pid, stamp])
                self.assertEqual(result.returncode, 0)
        finally:
            for pid, stamp in descendants.items():
                subprocess.run([str(self.f.bin / "mash-update-processes"), "term", pid, stamp], check=False)

    def test_wrong_start_identity_never_signals_process(self):
        child = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        result = subprocess.run([str(self.f.bin / "mash-update-processes"), "term", str(child.pid), "wrong-start"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(child.poll())

    def test_unrelated_host_process_is_not_inventory(self):
        child = self.f.start("/bin/sleep", "60")
        rows = self.f.inspector("list", self.f.app)
        self.assertNotIn(str(child.pid), rows.split())
        self.assertIsNone(child.poll())

    def test_uuid_rejects_invalid_inputs(self):
        bad = self.f.root / "not-an-executable"
        bad.write_bytes(b"invalid")
        result = subprocess.run([str(self.f.bin / "mash-update-processes"), "uuid", str(bad)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.f.inspector("uuid", self.f.app / "Contents/MacOS/mash-terminal")), 32)


if __name__ == "__main__":
    unittest.main()
