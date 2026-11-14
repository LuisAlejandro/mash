"""Sidebar refactors preserve selection, stale readings and startup retries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPERS = Path(__file__).resolve().parents[1] / "helpers"


class SidebarWatchersTest(unittest.TestCase):
    def test_poll_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo with spaces"
            repo.mkdir()
            def git(*args):
                subprocess.run(["git", "-C", str(repo), *args], check=True,
                               capture_output=True)
            git("init", "-b", "main")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            git("config", "remote.origin.url", str(root / "unused"))
            git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
            git("config", "branch.main.remote", "origin")
            git("config", "branch.main.merge", "refs/heads/main")
            tools = root / "bin"
            tools.mkdir()
            herdr = tools / "herdr"
            herdr.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
if sys.argv[1:] == ["pane", "list"]:
    print(json.dumps({"result": {"panes": json.loads(os.environ["PANES"])}}))
elif sys.argv[1:] == ["workspace", "list"]:
    print('{"result": {"workspaces": []}}')
else:
    with open(os.environ["REPORTS"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
    print('{"result": {}}')
''')
            gh = tools / "gh"
            gh.write_text('#!/bin/sh\n[ "${GH_FAIL:-}" != 1 ] || exit 1\nprintf "[]\\n"\n')
            herdr.chmod(0o755)
            gh.chmod(0o755)
            panes = [
                {"workspace_id": "selected", "foreground_cwd": str(repo)},
                # First pane wins, even when later panes name another cwd.
                {"workspace_id": "selected", "cwd": str(root / "missing")},
                {"workspace_id": "other", "cwd": str(repo)},
                {"workspace_id": "invalid", "cwd": str(root / "missing")},
            ]
            for helper in ("pr-watch-repo", "git-status-watch"):
                with self.subTest(helper=helper):
                    state = root / ".mash/local/state"
                    saved = state / helper / "state.json"
                    saved.parent.mkdir(parents=True, exist_ok=True)
                    reports = root / "reports"
                    env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                           "XDG_STATE_HOME": str(state), "PANES": json.dumps(panes),
                           "REPORTS": str(reports)}
                    args = [sys.executable, str(HELPERS / helper), "--workspace", "selected"]
                    if helper == "git-status-watch":
                        args.append("--no-fetch")
                    old = {"selected": {"ready": 3}, "other": {"keep": 42},
                           "closed": {"drop": 1}, "invalid": {"drop": 2}}
                    saved.write_text(json.dumps(old))
                    result = subprocess.run(args, env=env, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    current = json.loads(saved.read_text())
                    self.assertEqual({"selected", "other", "invalid"}, set(current))
                    self.assertEqual(old["other"], current["other"])
                    self.assertEqual(old["invalid"], current["invalid"])
                    self.assertIn("3 workspace(s) polled (refreshed selected)", result.stdout)
                    calls = [json.loads(line) for line in reports.read_text().splitlines()]
                    metadata = [call for call in calls if call[:2] == ["workspace", "report-metadata"]]
                    self.assertEqual(["selected"], [call[2] for call in metadata])
                    reports.unlink()

                    # A failed external lookup must retain the last reading.
                    saved.write_text(json.dumps(old))
                    failed_env = {**env, "GH_FAIL": "1"}
                    failed_args = [arg for arg in args if arg != "--no-fetch"]
                    result = subprocess.run(failed_args, env=failed_env, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(old["selected"], json.loads(saved.read_text())["selected"])

                    # No restored panes means retry, not successful empty state.
                    before = saved.read_bytes()
                    result = subprocess.run(args, env={**env, "PANES": "[]"}, capture_output=True)
                    self.assertEqual(1, result.returncode)
                    self.assertEqual(before, saved.read_bytes())


if __name__ == "__main__":
    unittest.main()
