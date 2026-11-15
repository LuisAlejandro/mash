#!/usr/bin/env python3
"""Real PTY: eight pages, source choices and all three model pickers; no writes."""
import fcntl
import json
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
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
DOWN = b"\x1b[B"
HOME = b"\x1b[H"
END = b"\x1b[F"


def read_frame(drain, redraw, process, expected=(), timeout=30):
    """Await page text, not the first chunk of the PTY byte stream."""
    output = b""
    text = ""
    deadline = time.monotonic() + timeout
    next_redraw = 0
    while time.monotonic() < deadline:
        now = time.monotonic()
        if process.poll() is None and now >= next_redraw:
            # Output may precede key processing or contain only an ANSI diff.
            redraw()
            next_redraw = now + 0.5
        chunk = drain(0.1)
        output += chunk
        if chunk:
            # Do not flood a slow reader with repeated full-screen repaints.
            next_redraw = time.monotonic() + 0.5
        text = ANSI.sub("", output.decode("utf-8", errors="replace"))
        if not chunk and text.strip() and all(needle in text for needle in expected):
            # Finish draining this redraw before the next key can be sent.
            return text
        if process.poll() is not None:
            if not expected:
                return text
            break
    raise AssertionError(
        f"wizard frame missing {expected!r}; exit={process.poll()}; output={text!r}"
    )


def wait_preview_exit(process, drain):
    # A child writing to a full PTY cannot exit until its output is consumed.
    deadline = time.monotonic() + 10
    while process.poll() is None and time.monotonic() < deadline:
        drain(0.05)
    return process.wait(timeout=1)


def stop_preview(process, drain):
    if process.poll() is None:
        process.kill()
    wait_preview_exit(process, drain)


class FrameReaderTest(unittest.TestCase):
    def test_waits_for_selected_page_and_drains_its_remaining_output(self):
        process = Mock()
        process.poll.return_value = None
        drain = Mock(side_effect=[
            b"old page", b"", b"Identity \xe2", b"\x80\x94 page 1/7",
            b"\x1b[20;1HSigning key", b"",
        ])
        output = read_frame(drain, Mock(), process, ("Identity — page 1/7",))
        self.assertIn("Identity — page 1/7", output)
        self.assertIn("Signing key", output, "do not return halfway through a redraw")
        self.assertEqual(drain.call_count, 6)

    def test_exited_preview_reports_missing_text_and_exit_status(self):
        process = Mock()
        process.poll.return_value = 3
        with self.assertRaisesRegex(AssertionError, "wizard frame missing.*exit=3"):
            read_frame(Mock(return_value=b"wrong page"), Mock(), process, ("Tools",))

    def test_failed_preview_is_drained_before_waiting_for_exit(self):
        process = Mock()
        process.poll.side_effect = [None, None, 0]
        drain = Mock(return_value=b"last output")
        stop_preview(process, drain)
        process.kill.assert_called_once()
        drain.assert_called_once_with(0.05)
        process.wait.assert_called_once_with(timeout=1)


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

                def redraw():
                    nonlocal columns
                    columns = width + (columns == width)
                    size()
                    os.kill(process.pid, signal.SIGWINCH)

                def frame(keys=b"", *expected):
                    if keys:
                        os.write(master, keys)
                    return read_frame(drain, redraw, process, expected)

                try:
                    initial = b""
                    deadline = time.monotonic() + 5
                    while "Choose your language" not in ANSI.sub("", initial.decode("utf-8", errors="replace")):
                        self.assertLess(time.monotonic(), deadline, "language page did not start")
                        initial += drain(0.1)
                    welcome = frame(b"\r", "Start config wizard")
                    self.assertIn("Start config wizard", welcome)
                    identity = frame(b"\r", "Identity — page 1/7", "Signing key", "Sign in to GitHub")
                    self.assertIn("Identity — page 1/7", identity)
                    self.assertIn("Signing key", identity)
                    self.assertIn("Sign in to GitHub", identity)
                    tools = frame(b"2", "Tools — page 2/7", "Install Programming Skills", "[x] agent-browser", "(Mash only)")
                    self.assertIn("Tools — page 2/7", tools)
                    self.assertIn("Install Programming Skills", tools)
                    self.assertIn("[x] agent-browser", tools)
                    self.assertIn("(Mash only)", tools)
                    self.assertIn("[ ] agent-browser", frame(b" ", "[ ] agent-browser"))
                    self.assertIn("[x] agent-browser", frame(b"\r", "[x] agent-browser"))

                    providers = frame(b"3", "Model provider — page 3/7", "Custom provider", "( ) OpenAI", "Connection details")
                    self.assertIn("Model provider — page 3/7", providers)
                    self.assertIn("Custom provider", providers)
                    self.assertIn("( ) OpenAI", providers)
                    self.assertIn("Connection details", providers)
                    frame(HOME + DOWN * 2 + b"\r")  # OpenAI, then credential selector.
                    deferred = frame(b"\r" + END + b"\r", "Sign in later in Pi")
                    self.assertIn("Sign in later in Pi", deferred)
                    self.assertIn("Filter models", frame(b"\t\t\r", "Filter models"))
                    self.assertIn("Model ID", frame(b"zzzz\r", "Model ID"))  # Manual remains reachable.
                    frame(b"\x1b")
                    self.assertIn("Z.AI Coding CN", frame(END, "Z.AI Coding CN"))
                    self.assertIn("(*) Z.AI Coding CN", frame(b" ", "(*) Z.AI Coding CN"))
                    frame(HOME + DOWN + b"\r")  # Custom provider is directly below Keep.
                    self.assertIn("Anthropic Messages", frame(b"\t\t\r" + END, "Anthropic Messages"))
                    frame(b"\r")
                    button = frame(b"\t\t\t\r", "Test connection", "Preview only")
                    self.assertIn("Test connection", button)
                    self.assertIn("Preview only", button)
                    self.assertNotIn("Press Enter: sends", button)

                    search = frame(b"4", "Web search — page 4/7", "Keep current: google/preview-search-model", "Use chat model")
                    self.assertIn("Web search — page 4/7", search)
                    self.assertIn("Keep current: google/preview-search-model", search)
                    self.assertIn("Use chat model", search)
                    frame(HOME + DOWN * 2 + b" ")  # Google uses its simulated saved credential.
                    source = frame(b"\t\t", "Use saved Pi credentials")
                    self.assertIn("Use saved Pi credentials", source)
                    picker = frame(b"\t\r", "Filter models", "preview-search-model")
                    self.assertIn("Filter models", picker)
                    self.assertIn("preview-search-model", picker)
                    memory = frame(b"\r", "Memory — page 5/7", "Custom endpoint/preview-memory-model")
                    self.assertIn("Memory — page 5/7", memory)
                    self.assertNotIn("Hindsight", memory)
                    self.assertIn("Custom endpoint/preview-memory-model", memory)
                    frame(END + b"\r")  # Existing custom memory connection.
                    self.assertIn("Keep saved memory key", frame(b"\t", "Keep saved memory key"))
                    picker = frame(b"\t\t\r", "Filter models", "preview-memory-model")
                    self.assertIn("Filter models", picker)
                    self.assertIn("preview-memory-model", picker)
                    self.assertIn("Model ID", frame(END + b"\r", "Model ID"))
                    frame(b"\x1b")
                    for page in (6, 7):
                        self.assertIn(f"page {page}/7", frame(str(page).encode(), f"page {page}/7"))
                    dictation = frame(b"7", "page 7/7")
                    self.assertNotIn("Skip dictation", dictation)
                    self.assertIn("Start config wizard", frame(b"\x1b", "Start config wizard"))
                    os.write(master, b"\x03")
                    self.assertEqual(wait_preview_exit(process, drain), 3)
                    self.assertEqual(list(home.rglob("*")), [], "preview wrote data or launched a helper")
                finally:
                    try:
                        stop_preview(process, drain)
                    finally:
                        os.close(master)
                        os.close(slave)

    def test_language_and_tools_pages_fit_all_catalogs_at_80x24(self):
        languages = json.loads((ROOT / "packaging/i18n/languages.json").read_text())
        codes = [row["code"] for row in languages]
        english_index = codes.index("en")
        for row in languages:
            code = row["code"]
            catalog = json.loads(
                (ROOT / "packaging/i18n/messages/wizard" / f"{code}.json").read_text()
            )
            message = lambda key: catalog[key]["text"] if isinstance(catalog[key], dict) else catalog[key]
            page_title = lambda key, page: message("wizard.shell.page_title").format(
                title=message(key), current=page, total=7
            )
            with self.subTest(language=code), tempfile.TemporaryDirectory(prefix="mash-language-") as tmp:
                home = Path(tmp) / "home"
                home.mkdir()
                resources = Path(tmp) / "resources"
                resources.mkdir()
                master, slave = pty.openpty()

                def attach():
                    os.setsid()
                    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
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

                columns = 80

                def size():
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))

                def redraw():
                    nonlocal columns
                    columns = 81 if columns == 80 else 80
                    size()
                    os.kill(process.pid, signal.SIGWINCH)

                def frame(keys=b"", *expected):
                    if keys:
                        os.write(master, keys)
                    return read_frame(drain, redraw, process, expected)

                try:
                    initial = b""
                    deadline = time.monotonic() + 5
                    while "Choose your language" not in ANSI.sub("", initial.decode("utf-8", errors="replace")):
                        self.assertLess(time.monotonic(), deadline, "language page did not start")
                        initial += drain(0.1)
                    delta = codes.index(code) - english_index
                    move = DOWN if delta > 0 else b"\x1b[A"
                    lang_screen = frame(
                        move * abs(delta), row["name"], message("wizard.language.continue")
                    )
                    self.assertIn(row["name"], lang_screen)
                    self.assertIn(message("wizard.language.continue"), lang_screen)
                    welcome = frame(b"\r", message("wizard.welcome.start"))
                    self.assertIn(message("wizard.welcome.start"), welcome)
                    identity = frame(b"\r", page_title("wizard.identity.title", 1))
                    self.assertIn(page_title("wizard.identity.title", 1), identity)
                    tools = frame(b"2", page_title("wizard.tools.title", 2), message("wizard.tools.next"))
                    self.assertIn(page_title("wizard.tools.title", 2), tools)
                    self.assertIn(message("wizard.tools.next"), tools)
                    if code == "es":
                        voice_page = frame(b"7", "[x] Español")
                        self.assertIn("[x] Español", voice_page)
                    frame(b"\x1b", message("wizard.welcome.start"))
                    os.write(master, b"\x1b")
                    self.assertEqual(wait_preview_exit(process, drain), 3)
                    self.assertEqual(list(home.rglob("*")), [], "preview wrote setup state")
                finally:
                    try:
                        stop_preview(process, drain)
                    finally:
                        os.close(master)
                        os.close(slave)


if __name__ == "__main__":
    if os.name != "posix" or not shutil.which("cargo"):
        print("SKIP: PTY/cargo unavailable")
        raise SystemExit(77)
    unittest.main()
