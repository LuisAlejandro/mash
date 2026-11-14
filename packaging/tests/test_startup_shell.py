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
            "herdr-fresh-pane": "printf 'EDITOR-READY %s\\n' \"$*\"\n",
        }.items():
            path = self.bin / name
            path.write_text("#!/bin/sh\n" + body)
            path.chmod(0o755)
        self.record = self.root / "local/state/dev-tab-park/w1_p1"
        self.spawn("600")

    def spawn(self, grace):
        pid, self.fd = pty.fork()
        if pid == 0:
            env = {**os.environ, "PATH": str(self.bin) + ":/usr/bin:/bin",
                   "MASH_DATA_DIR": str(self.root), "HERDR_PANE_ID": "w1:p1",
                   "MASH_STARTUP_GRACE": grace,
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
        # Idempotent: setUp's cleanup and a test that re-spawns both call it.
        pid, self.pid = getattr(self, "pid", None), None
        if pid is None:
            return
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

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

    def test_a_stray_reply_cannot_eat_the_launch(self):
        # The parker wakes a pane with a bare `:` first, for exactly this: a
        # terminal reply still in flight lands on that line instead of gluing
        # itself to the command name.
        os.write(self.fd, b"DS\nherdr-fresh-pane --daemon .\n")
        self.wait_for(b"EDITOR-READY --daemon .")

    def test_handing_the_pane_back_turns_terminal_modes_off(self):
        # The program that enabled mouse reporting died; the shell that gets the
        # pane back must turn it off, or every pointer move is typed into it.
        self.stop()
        self.output.clear()
        self.spawn("1")
        self.wait_for(b"USER-SHELL-READY")
        self.assertIn(b"\x1b[?1000l", self.output)
        self.assertIn(b"\x1b[?1006l", self.output)
        self.assertIn(b"\x1b[?2004l", self.output)

    def test_parked_quiet_prompt_resets_modes_after_foreground_exit(self):
        self.record.parent.mkdir(parents=True, exist_ok=True)
        self.record.write_text("{}")
        program = self.bin / "mode-agent"
        program.write_text("#!/bin/sh\nprintf '\\033[?1000h\\033[?1006hAPP-EXIT\\n'\n")
        program.chmod(0o755)
        os.write(self.fd, (shlex.quote(str(program)) + "\n").encode())
        self.wait_for(b"APP-EXIT")
        self.wait_for(b"\x1b]133;B\x07")
        after_exit = bytes(self.output).split(b"APP-EXIT", 1)[1]
        # This proves emitted cleanup, not terminal-emulator mouse behavior.
        self.assertIn(b"\x1b[?1000l", after_exit)
        self.assertIn(b"\x1b[?1006l", after_exit)
        self.assertNotIn(b"USER-SHELL-READY", self.output)

    def test_a_launch_that_never_arrives_hands_the_pane_back(self):
        # No command is ever typed. Without a grace period the pane sits here
        # for ever: echo off, nothing reading input, just "Starting the editor".
        self.stop()
        self.spawn("1")
        self.wait_for(b"USER-SHELL-READY")

    def test_a_parked_pane_is_not_handed_back_while_its_record_stands(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text("{}")
        self.stop()
        self.spawn("1")
        time.sleep(3)
        self.assertNotIn(b"USER-SHELL-READY", self.output)
        self.record.unlink()
        self.stop()

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
