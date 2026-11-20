#!/usr/bin/env python3
"""Test park/reattach against a built Mash Fresh binary on a real Unix PTY."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


def park(fresh, name, project, env):
    master, slave = pty.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        interactive = termios.ICANON | termios.ECHO | termios.ISIG
        original = termios.tcgetattr(slave)[3] & interactive
        with subprocess.Popen(
            [fresh, "--no-plugins", "-a", name], cwd=project, env=env,
            stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
        ) as client:
            def read_until(done):
                output = bytearray()
                deadline = time.monotonic() + 10
                while not done(output):
                    left = deadline - time.monotonic()
                    assert left > 0, bytes(output[-500:])
                    if select.select([master], [], [], min(left, 0.05))[0]:
                        output.extend(os.read(master, 65536))
                return output

            try:
                read_until(lambda out: b"\x1b[?1006h" in out)
                assert not (termios.tcgetattr(slave)[3] & interactive), "client never entered raw mode"
                client.terminate()
                teardown = read_until(lambda out: client.poll() is not None)
                while select.select([master], [], [], 0)[0]:
                    teardown.extend(os.read(master, 65536))
                assert b"\x1b[?1006l" in teardown, "parking left mouse reporting enabled"
                assert b"\x1b[?1049l" in teardown, "parking left the alternate screen active"
                assert termios.tcgetattr(slave)[3] & interactive == original, "parking left the PTY in raw mode"
                assert client.returncode == 0, "client did not detach normally"
            finally:
                if client.poll() is None:
                    client.kill()
    finally:
        os.close(slave)
        os.close(master)


def main(fresh):
    name = f"mash-park-test-{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="mash-fresh-pty-", dir="/tmp") as home:
        root = Path(home)
        project, config, data, run = (root / d for d in ("project", "config", "data", "run"))
        for directory in (project, config, data, run):
            directory.mkdir()
        (config / "config.json").write_text('{"check_for_updates":false,"mouse_capture":true}')
        env = {
            "PATH": os.environ["PATH"], "HOME": home, "TMPDIR": home, "TERM": "xterm-256color",
            "MASH_FRESH_CONFIG_DIR": str(config), "MASH_FRESH_DATA_DIR": str(data),
            "XDG_CONFIG_HOME": home, "XDG_DATA_HOME": home, "XDG_STATE_HOME": home,
            "XDG_CACHE_HOME": home, "XDG_RUNTIME_DIR": str(run),
        }
        try:
            park(fresh, name, project, env)
            pid_file, = root.rglob(f"{name}.pid")
            pid = pid_file.read_text()
            os.kill(int(pid), 0)
            park(fresh, name, project, env)
            assert pid_file.read_text() == pid, "reattach replaced the daemon"
        finally:
            subprocess.run([fresh, "--cmd", "daemon", "kill", name], cwd=project, env=env,
                           capture_output=True, timeout=10, check=False)


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve(strict=True)))
