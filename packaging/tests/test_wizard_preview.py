#!/usr/bin/env python3
"""Real PTY journey: six pages and model/manual selection, with no setup writes."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


@unittest.skipUnless(os.name == "posix" and shutil.which("cargo"), "PTY/cargo unavailable")
class WizardPreviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["cargo", "build", "--locked", "--manifest-path", str(ROOT / "packaging/wizard/Cargo.toml")], check=True, capture_output=True)
        cls.binary = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "packaging/wizard/target")) / "debug/mash-wizard"

    def test_six_page_keyboard_journey_and_manual_fallback_are_read_only(self):
        for width in (80, 100):
            with self.subTest(width=width), tempfile.TemporaryDirectory(prefix="mash-preview-") as tmp:
                home = Path(tmp) / "home"
                home.mkdir()
                master, slave = pty.openpty()
                columns = width

                def size():
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30 if width == 100 else 24, columns, 0, 0))

                def attach():
                    os.setsid()
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

                size()
                process = subprocess.Popen([str(self.binary), "--preview"], stdin=slave, stdout=slave, stderr=slave,
                                           cwd=ROOT, preexec_fn=attach,
                                           env={"HOME": str(home), "PATH": os.environ["PATH"], "TERM": "xterm-256color", "MASH_RES_ROOT": str(Path(tmp) / "absent-resources")})

                def drain(seconds):
                    output = b""
                    until = time.monotonic() + seconds
                    while time.monotonic() < until:
                        ready, _, _ = select.select([master], [], [], max(0, until - time.monotonic()))
                        if ready:
                            try:
                                output += os.read(master, 65536)
                            except OSError:
                                break
                    return output

                def frame(keys=b""):
                    nonlocal columns
                    if keys:
                        os.write(master, keys)
                    # A resize forces a full redraw, not a diff against a prior page.
                    drain(0.12)
                    columns = width + (columns == width)
                    size()
                    os.kill(process.pid, signal.SIGWINCH)
                    raw = drain(0.2).decode("utf-8", errors="replace")
                    return ANSI.sub("", raw)

                try:
                    initial = b""
                    deadline = time.monotonic() + 5
                    while "Start config wizard" not in ANSI.sub("", initial.decode("utf-8", errors="replace")):
                        self.assertLess(time.monotonic(), deadline, "wizard never reached its welcome screen")
                        initial += drain(0.1)
                    self.assertIn("page 1/6", frame(b"\r"))
                    self.assertIn("page 2/6", frame(b"2"))
                    frame(b"\r\x1b[B\r")  # Choose OpenAI.
                    self.assertIn("Filter models", frame(b"\t\t\t\r"))
                    self.assertIn("Model ID", frame(b"zzzz\r"))  # Always-available manual entry.
                    self.assertIn("Choose model", frame(b"\x1b"))
                    services = frame(b"3")
                    self.assertIn("page 3/6", services)
                    self.assertIn("Web search", services)
                    self.assertIn("Hindsight", services)
                    for page in (4, 5, 6):
                        self.assertIn(f"page {page}/6", frame(str(page).encode()))
                    self.assertIn("Start config wizard", frame(b"\x1b"))
                    os.write(master, b"\x03")
                    deadline = time.monotonic() + 5
                    while process.poll() is None:
                        self.assertLess(time.monotonic(), deadline, "wizard did not exit")
                        drain(0.05)
                    process.wait()
                    self.assertEqual(process.returncode, 3)
                    self.assertEqual(list(home.rglob("*")), [], "preview wrote user settings or state")
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
                    os.close(slave)


if __name__ == "__main__":
    unittest.main()
