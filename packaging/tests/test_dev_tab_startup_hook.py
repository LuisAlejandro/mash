#!/usr/bin/env python3
"""The real tab.created hook must accept Mash's real quiet startup shell.

Unlike the PATH regression, this registers the plugin and lets Herdr deliver
actual events. Only the editor/agent layout builder is replaced: it splits the
pane without starting agents. Everything that caused the failure -- Bash's
startup rc, its background grace timer, process-info, and the hook -- is real.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERDR = shutil.which("herdr")


@unittest.skipUnless(HERDR, "Herdr is required for the real tab-created regression")
class QuietStartupHookTest(unittest.TestCase):
    def test_rapid_tabs_are_split_with_the_grace_timer_running(self):
        with tempfile.TemporaryDirectory(prefix="mash-plus-", dir="/tmp") as tmp:
            root = Path(tmp)
            bins = root / "bundle/bin"
            plugin = root / "bundle/plugins/dev-tab"
            for d in (bins, plugin, root / "work", root / "cfg", root / "state", root / "data"):
                d.mkdir(parents=True, exist_ok=True)
            hook = Path(os.environ.get("MASH_TEST_DEV_TAB_HOOK", ROOT / "packaging/plugins/dev-tab/dev-tab.sh"))
            shutil.copy2(hook, plugin / "dev-tab.sh")
            manifest = (ROOT / "packaging/plugins/dev-tab/herdr-plugin.toml").read_text()
            # Give the actual shell time to enter its quiet rc, rather than
            # accidentally accepting its short-lived /bin/sh bootstrap process.
            (plugin / "event.sh").write_text("#!/bin/sh\nsleep 1\nexec bash ./dev-tab.sh\n")
            (plugin / "herdr-plugin.toml").write_text(
                manifest.replace('["bash", "dev-tab.sh"]', '["bash", "event.sh"]'))
            shutil.copy2(ROOT / "packaging/helpers/mash-startup-shell", bins / "mash-startup-shell")
            for name, body in {
                "pane-shell": f'export MASH_STARTUP_SHELL_RC=1\nexec /bin/bash --noprofile --rcfile "{bins}/mash-startup-shell" --noediting -i\n',
                "mash-pane-starting": "printf 'Starting the editor...\\n'\n",
                "mash-shell": "exec /bin/sh\n",
                "herdr-dev-tab-fill": 'exec "$HERDR_BIN_PATH" pane split "$1" --direction right --ratio 0.6 --no-focus\n',
            }.items():
                path = bins / name
                path.write_text("#!/bin/sh\n" + body)
                path.chmod(0o755)
            config = root / "herdr.toml"
            config.write_text(f'onboarding = false\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "{bins}/pane-shell"\n')
            # Do not inherit a live pane identity, server socket, or plugin
            # override. This server and every process it creates are disposable.
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("HERDR_", "MASH_"))}
            env.update(HOME=str(root), PATH=f"{bins}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                       MASH_BIN=str(bins), MASH_DATA_DIR=str(root / "data"),
                       MASH_STARTUP_GRACE="120", SHELL="/bin/bash",
                       PYTHONDONTWRITEBYTECODE="1", HERDR_SOCKET_PATH=str(root / "h.sock"),
                       HERDR_CLIENT_SOCKET_PATH=str(root / "c.sock"), HERDR_CONFIG_PATH=str(config),
                       XDG_CONFIG_HOME=str(root / "cfg"), XDG_DATA_HOME=str(root / "data"),
                       XDG_STATE_HOME=str(root / "state"), XDG_CACHE_HOME=str(root / "cache"))

            def call(method, params=None):
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.settimeout(5)
                    sock.connect(env["HERDR_SOCKET_PATH"])
                    sock.sendall((json.dumps({"id": "test", "method": method, "params": params or {}}) + "\n").encode())
                    with sock.makefile("rb") as stream:
                        reply = json.loads(stream.readline())
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply["result"]

            def cli(*args):
                return subprocess.run([HERDR, *args], env=env, cwd=root / "work",
                                      capture_output=True, text=True, timeout=20)

            server = subprocess.Popen([HERDR, "server"], env=env, cwd=root / "work",
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        call("workspace.list")
                        break
                    except (OSError, ValueError):
                        if time.monotonic() >= deadline:
                            self.fail("isolated Herdr did not start")
                        time.sleep(.1)
                workspace = call("workspace.create", {"cwd": str(root / "work")})["workspace"]["workspace_id"]
                linked = cli("plugin", "link", str(plugin))
                self.assertEqual(linked.returncode, 0, linked.stderr)
                tabs = [call("tab.create", {"workspace_id": workspace, "cwd": str(root / "work"), "focus": False})["tab"]["tab_id"]
                        for _ in range(8)]
                deadline = time.monotonic() + 15
                counts = {}
                while time.monotonic() < deadline:
                    counts = {t["tab_id"]: t["pane_count"] for t in call("tab.list", {"workspace_id": workspace})["tabs"]}
                    if all(counts.get(t) == 2 for t in tabs):
                        break
                    time.sleep(.2)
                failed = {t: counts.get(t) for t in tabs if counts.get(t) != 2}
                self.assertFalse(failed, f"tab.created rejected the quiet shell while its timer ran: {failed}")
            finally:
                cli("server", "stop")
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.terminate()
                    server.wait(timeout=10)


if __name__ == "__main__":
    if not HERDR:
        print("SKIP: Herdr not installed")
        sys.exit(77)
    unittest.main()
