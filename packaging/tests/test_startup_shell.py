#!/usr/bin/env python3
"""Exercise real terminal echo, not a mocked pane or a post-clear screenshot."""
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL = ROOT / "packaging/helpers/mash-startup-shell"


class StartupShellTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="mash startup ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in {
            "mash-pane-starting": "printf '\\033[2J\\033[HLOADER-READY\\n'\n",
            "mash-shell": "printf 'USER-SHELL-READY\\n'; exec /bin/sh\n",
            "fake-agent": "sleep 0.1; printf 'APP-READY\\n'\n",
        }.items():
            path = self.bin / name
            path.write_text("#!/bin/sh\n" + body)
            path.chmod(0o755)
        self.record = self.root / "local/state/dev-tab-park/w1_p1"
        pid, self.fd = pty.fork()
        if pid == 0:
            env = {**os.environ, "PATH": str(self.bin) + ":/usr/bin:/bin",
                   "MASH_DATA_DIR": str(self.root), "HERDR_PANE_ID": "w1:p1",
                   "MASH_PANE_STARTUP": "agent"}
            env.pop("MASH_STARTUP_SHELL_RC", None)
            os.execve(str(SHELL), [str(SHELL)], env)
        self.pid = pid
        self.output = bytearray()
        self.addCleanup(self.stop)
        self.wait_for(b"LOADER-READY")
        deadline = time.monotonic() + 3
        while termios.tcgetattr(self.fd)[3] & termios.ECHO:
            if time.monotonic() >= deadline:
                self.fail("startup shell did not disable echo")
            time.sleep(0.01)
        self.wait_for(b"\x1b]133;B\x07")
        self.output.clear()

    def stop(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        os.waitpid(self.pid, 0)

    def wait_for(self, marker):
        deadline = time.monotonic() + 5
        while marker not in self.output:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, repr(bytes(self.output)))
            if select.select([self.fd], [], [], remaining)[0]:
                self.output.extend(os.read(self.fd, 8192))

    def command(self):
        return shlex.quote(str(self.bin / "fake-agent")) + " --session NEVER-ECHO-THIS\n"

    def test_first_command_never_appears_in_the_terminal_stream(self):
        os.write(self.fd, self.command().encode())
        self.wait_for(b"APP-READY")
        self.wait_for(b"USER-SHELL-READY")
        self.assertNotIn(b"NEVER-ECHO-THIS", self.output)
        self.assertNotIn(b"fake-agent", self.output)
        self.assertTrue(termios.tcgetattr(self.fd)[3] & termios.ECHO, "restore echo for the user shell")

    def test_parked_pane_wakes_without_showing_a_prompt_or_command(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text("{}")
        os.write(self.fd, self.command().encode())
        self.wait_for(b"APP-READY")
        # Wait for Bash's next quiet prompt, indicated by its OSC readiness.
        self.wait_for(b"\x1b]133;B\x07")
        self.assertNotIn(b"USER-SHELL-READY", self.output)
        self.output.clear()
        self.record.unlink()
        os.write(self.fd, self.command().encode())
        self.wait_for(b"APP-READY")
        self.wait_for(b"USER-SHELL-READY")
        self.assertNotIn(b"NEVER-ECHO-THIS", self.output)
        self.assertNotIn(b"fake-agent", self.output)


if __name__ == "__main__":
    unittest.main()
