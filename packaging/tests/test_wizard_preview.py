#!/usr/bin/env python3
"""Real PTY: eight pages, source choices and all three model pickers; no writes."""
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
DOWN = b"\x1b[B"
HOME = b"\x1b[H"
END = b"\x1b[F"


@unittest.skipUnless(os.name == "posix" and shutil.which("cargo"), "PTY/cargo unavailable")
class WizardPreviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(
            ["cargo", "build", "--locked", "--manifest-path", str(ROOT / "packaging/wizard/Cargo.toml")],
            check=True, capture_output=True,
        )
        cls.binary = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "packaging/wizard/target")) / "debug/mash-wizard"

    def test_eight_page_keyboard_journey_is_simulated_and_read_only(self):
        for width in (80, 100):
            with self.subTest(width=width), tempfile.TemporaryDirectory(prefix="mash-preview-") as tmp:
                home = Path(tmp) / "home"
                home.mkdir()
                resources = Path(tmp) / "resources"
                node = resources / "node/bin/node"
                node.parent.mkdir(parents=True)
                node.write_text('#!/bin/sh\nprintf launched > "$HOME/helper-launched"\nexit 99\n')
                node.chmod(0o755)
                master, slave = pty.openpty()
                columns = width

                def size():
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack(
                        "HHHH", 30 if width == 100 else 24, columns, 0, 0,
                    ))

                def attach():
                    os.setsid()
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

                size()
                process = subprocess.Popen(
                    [str(self.binary), "--preview"], stdin=slave, stdout=slave, stderr=slave,
                    cwd=ROOT, preexec_fn=attach,
                    env={"HOME": str(home), "PATH": os.environ["PATH"], "TERM": "xterm-256color",
                         "MASH_RES_ROOT": str(resources)},
                )

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
                    drain(0.12)
                    # A resize requests a full frame, not an ANSI diff.
                    columns = width + (columns == width)
                    size()
                    os.kill(process.pid, signal.SIGWINCH)
                    return ANSI.sub("", drain(0.25).decode("utf-8", errors="replace"))

                try:
                    initial = b""
                    deadline = time.monotonic() + 5
                    while "Start config wizard" not in ANSI.sub("", initial.decode("utf-8", errors="replace")):
                        self.assertLess(time.monotonic(), deadline, "wizard did not start")
                        initial += drain(0.1)
                    identity = frame(b"\r")
                    self.assertIn("Identity — page 1/7", identity)
                    self.assertIn("Signing key", identity)
                    self.assertIn("Sign in to GitHub", identity)
                    tools = frame(b"2")
                    self.assertIn("Tools — page 2/7", tools)
                    self.assertIn("Install Programming Skills", tools)
                    self.assertIn("[x] agent-browser", tools)
                    self.assertIn("(Mash only)", tools)
                    self.assertIn("[ ] agent-browser", frame(b" "))
                    self.assertIn("[x] agent-browser", frame(b"\r"))

                    providers = frame(b"3")
                    self.assertIn("Model provider — page 3/7", providers)
                    self.assertIn("Custom provider", providers)
                    self.assertIn("( ) OpenAI", providers)
                    self.assertIn("Connection details", providers)
                    frame(HOME + DOWN * 2 + b"\r")  # OpenAI, then credential selector.
                    deferred = frame(b"\r" + END + b"\r")
                    self.assertIn("Sign in later in Pi", deferred)
                    self.assertIn("Filter models", frame(b"\t\t\r"))
                    self.assertIn("Model ID", frame(b"zzzz\r"))  # Manual remains reachable.
                    frame(b"\x1b")
                    self.assertIn("Z.AI Coding CN", frame(END))
                    self.assertIn("(*) Z.AI Coding CN", frame(b" "))
                    frame(HOME + DOWN + b"\r")  # Custom provider is directly below Keep.
                    self.assertIn("Anthropic Messages", frame(b"\t\t\r" + END))
                    frame(b"\r")
                    button = frame(b"\t\t\t\r")
                    self.assertIn("Test connection", button)
                    self.assertIn("Preview only", button)
                    self.assertNotIn("Press Enter: sends", button)

                    search = frame(b"4")
                    self.assertIn("Web search — page 4/7", search)
                    self.assertIn("Keep current: google/preview-search-model", search)
                    self.assertIn("Use chat model", search)
                    frame(HOME + DOWN * 2 + b" ")  # Google uses its simulated saved credential.
                    source = frame(b"\t\t")
                    self.assertIn("Use saved Pi credentials", source)
                    picker = frame(b"\t\r")
                    self.assertIn("Filter models", picker)
                    self.assertIn("preview-search-model", picker)
                    memory = frame(b"\r")  # Accepting the search model continues to Memory.
                    self.assertIn("Memory — page 5/7", memory)
                    self.assertNotIn("Hindsight", memory)
                    self.assertIn("Custom endpoint/preview-memory-model", memory)
                    frame(END + b"\r")  # Existing custom memory connection.
                    self.assertIn("Keep saved memory key", frame(b"\t"))
                    picker = frame(b"\t\t\r")
                    self.assertIn("Filter models", picker)
                    self.assertIn("preview-memory-model", picker)
                    self.assertIn("Model ID", frame(END + b"\r"))
                    frame(b"\x1b")
                    for page in (6, 7):
                        self.assertIn(f"page {page}/7", frame(str(page).encode()))
                    dictation = frame(b"7")
                    self.assertNotIn("Skip dictation", dictation)
                    self.assertIn("Start config wizard", frame(b"\x1b"))
                    os.write(master, b"\x03")
                    deadline = time.monotonic() + 5
                    while process.poll() is None:
                        self.assertLess(time.monotonic(), deadline, "wizard did not exit")
                        drain(0.05)
                    process.wait()
                    self.assertEqual(process.returncode, 3)
                    self.assertEqual(list(home.rglob("*")), [], "preview wrote data or launched a helper")
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
                    os.close(slave)


if __name__ == "__main__":
    if os.name != "posix" or not shutil.which("cargo"):
        print("SKIP: PTY/cargo unavailable")
        raise SystemExit(77)
    unittest.main()
