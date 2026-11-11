"""Reopen Tab: snapshot tabs on the way out, rebuild them on the way back.

The helper is driven against a stub Herdr so the three decisions it owns can be
checked without a server: which tabs a close buries, what a reopen recreates
from them, and what it does when there is nothing to reopen. The stub answers
the socket-API calls the helper makes and records every mutating one, so the
rebuild is asserted from the commands Mash would really send.

Run with: python3 packaging/tests/test_reopen_tab.py
"""

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

HELPERS = Path(__file__).resolve().parents[1] / "helpers"

# A stand-in herdr: canned reads from $STUB_STATE, every call appended to
# $STUB_CALLS, and creations/splits that mint ids the way Herdr's do.
STUB = r'''#!/usr/bin/env python3
import json, os, sys

state_path = os.environ["STUB_STATE"]
calls_path = os.environ["STUB_CALLS"]
args = sys.argv[1:]
state = json.load(open(state_path))

with open(calls_path, "a") as handle:
    handle.write(json.dumps(args) + "\n")

def save():
    with open(state_path, "w") as handle:
        json.dump(state, handle)

def result(payload):
    print(json.dumps({"id": "stub", "result": payload}))
    return 0

verb = args[0] if args else ""
if verb == "tab" and args[1:] == ["list"]:
    sys.exit(result({"tabs": state["tabs"]}))
if verb == "pane" and args[1:] == ["list"]:
    sys.exit(result({"panes": state["panes"]}))
if verb == "pane" and args[1:2] == ["layout"]:
    sys.exit(result({"layout": state["layout"]}))
if verb == "workspace" and args[1:] == ["list"]:
    sys.exit(result({"workspaces": state["workspaces"]}))
if verb == "tab" and args[1:2] == ["create"]:
    state["minted"] = state.get("minted", 0) + 1
    n = state["minted"]
    tab_id, pane_id = f"w9:tNEW{n}", f"w9:pNEW{n}"
    state["tabs"].append({"tab_id": tab_id, "workspace_id": "w9", "label": ""})
    state["panes"].append({"tab_id": tab_id, "pane_id": pane_id, "cwd": os.environ["STUB_CWD"],
                           "agent": "", "focused": True})
    save()
    sys.exit(result({"tab_id": tab_id, "pane_id": pane_id}))
if verb == "pane" and args[1:2] == ["split"]:
    state["minted"] = state.get("minted", 0) + 1
    n = state["minted"]
    pane_id = f"w9:pNEW{n}"
    state["panes"].append({"tab_id": "w9:tNEW1", "pane_id": pane_id, "cwd": "", "agent": ""})
    save()
    sys.exit(result({"pane_id": pane_id}))
if verb == "pane" and args[1:2] == ["run"]:
    sys.exit(result({"pane_id": args[2]}))
if verb == "tab" and args[1:2] == ["rename"]:
    sys.exit(result({"tab_id": args[2]}))
if verb == "notification":
    sys.exit(result({"shown": True}))
sys.exit(2)
'''


def write_exec(path, text):
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class ReopenTabTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        # The helper resolves its interpreter and pi from a mash-bin beside it,
        # so it is copied next to a stub rather than run from the repo tree.
        self.bin = self.tmp / "helpers"
        self.bin.mkdir()
        for name in ("herdr-tabs", "herdr_tabs.py"):
            shutil.copy2(HELPERS / name, self.bin / name)
        self.pi = self.tmp / "bin" / "pi"
        self.pi.parent.mkdir()
        write_exec(self.pi, "#!/bin/sh\nexit 0\n")
        write_exec(
            self.bin / "mash-bin",
            '#!/bin/sh\ncase "$1" in\n--bundled) printf "%s\\n" "$FAKE_PI" ;;\n'
            'python3) command -v python3 ;;\nesac\n',
        )
        write_exec(self.tmp / "bin" / "herdr", STUB)
        self.session = self.tmp / "session.jsonl"
        self.session.write_text("{}\n")
        self.state = self.tmp / "state.json"
        self.calls = self.tmp / "calls.jsonl"
        self.calls.write_text("")
        self.stack = self.tmp / "state" / "mash" / "closed-tabs" / "stack.json"
        self.cache = self.tmp / "state" / "mash" / "closed-tabs" / "cache.json"

    def env(self, **extra):
        base = {
            "PATH": f"{self.tmp / 'bin'}:/usr/bin:/bin",
            "HOME": str(self.tmp),
            "XDG_STATE_HOME": str(self.tmp / "state"),
            "HERDR_BIN_PATH": str(self.tmp / "bin" / "herdr"),
            "STUB_STATE": str(self.state),
            "STUB_CALLS": str(self.calls),
            "STUB_CWD": str(self.tmp),
            "FAKE_PI": str(self.pi),
        }
        base.update(extra)
        return base

    def run_action(self, action, **extra):
        done = subprocess.run(
            [str(self.bin / "herdr-tabs"), action],
            capture_output=True,
            text=True,
            env=self.env(**extra),
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        return done

    def calls_made(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines() if line]

    def seed(self, tabs, panes, layout=None, workspaces=("w5", "w9")):
        self.state.write_text(
            json.dumps(
                {
                    "tabs": tabs,
                    "panes": panes,
                    "layout": layout or {"panes": [], "splits": []},
                    "workspaces": [{"workspace_id": w} for w in workspaces],
                }
            )
        )

    def dev_tab(self, workspace="w5"):
        tabs = [
            {"tab_id": "w5:t1", "workspace_id": workspace, "label": "4 · pi › π - app"},
            {"tab_id": "w5:t2", "workspace_id": workspace, "label": "5 · π - app"},
        ]
        panes = [
            {"tab_id": "w5:t1", "pane_id": "w5:p1", "cwd": "/work/app", "agent": "fresh",
             "focused": False},
            {"tab_id": "w5:t1", "pane_id": "w5:p2", "cwd": "/work/app", "agent": "pi",
             "agent_session": {"value": str(self.session)}, "focused": True},
            {"tab_id": "w5:t2", "pane_id": "w5:p3", "cwd": "/work/other", "agent": "",
             "focused": True},
        ]
        layout = {
            "panes": [
                {"pane_id": "w5:p1", "rect": {"x": 0, "y": 0, "width": 60, "height": 40}},
                {"pane_id": "w5:p2", "rect": {"x": 60, "y": 0, "width": 40, "height": 40}},
            ],
            "splits": [{"direction": "right", "ratio": 0.6,
                        "rect": {"x": 0, "y": 0, "width": 100, "height": 40}}],
        }
        self.seed(tabs, panes, layout)

    def close_tab(self, tab_id):
        state = json.loads(self.state.read_text())
        state["tabs"] = [tab for tab in state["tabs"] if tab["tab_id"] != tab_id]
        state["panes"] = [pane for pane in state["panes"] if pane["tab_id"] != tab_id]
        self.state.write_text(json.dumps(state))

    def test_capture_records_layout_and_programs(self):
        self.dev_tab()
        self.run_action("capture")
        cache = json.loads(self.cache.read_text())
        self.assertEqual([t["tab_id"] for t in cache["tabs"]], ["w5:t1", "w5:t2"])
        first = cache["tabs"][0]
        self.assertEqual(first["label"], "4 · pi › π - app")
        self.assertEqual(first["splits"], [{"direction": "right", "ratio": 0.6}])
        self.assertEqual(
            [(p["cwd"], p["agent"]) for p in first["panes"]],
            [("/work/app", "fresh"), ("/work/app", "pi")],
        )
        self.assertEqual(first["panes"][1]["session"], str(self.session))

    def test_capture_keeps_a_snapshot_the_close_has_not_buried_yet(self):
        # Closing a tab fires pane.closed before tab.closed, so a capture can
        # land between the tab disappearing and the close hook running.
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("capture")
        cache = {t["tab_id"]: t for t in json.loads(self.cache.read_text())["tabs"]}
        self.assertIn("w5:t1", cache)
        self.assertEqual(len(cache["w5:t1"]["panes"]), 2)
        self.run_action("closed")
        self.assertEqual(
            [t["tab_id"] for t in json.loads(self.stack.read_text())], ["w5:t1"]
        )

    def test_closed_buries_only_the_vanished_tab(self):
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("closed")
        stack = json.loads(self.stack.read_text())
        self.assertEqual([t["tab_id"] for t in stack], ["w5:t1"])
        cache = json.loads(self.cache.read_text())
        self.assertEqual([t["tab_id"] for t in cache["tabs"]], ["w5:t2"])

    def test_closed_ignores_a_stale_cache_entry_for_the_same_tab(self):
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("closed")
        # A capture racing the close wrote the tab back into the cache.
        self.run_action("capture")
        stale = json.loads(self.cache.read_text())["tabs"] + [
            {"tab_id": "w5:t1", "workspace_id": "w5", "label": "", "splits": [],
             "panes": [{"cwd": "/work/app", "agent": "", "session": ""}]}
        ]
        self.cache.write_text(json.dumps({"tabs": stale}))
        self.run_action("closed")
        self.assertEqual(len(json.loads(self.stack.read_text())), 1)

    def test_reopen_rebuilds_the_tab_in_its_workspace(self):
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("closed")
        self.calls.write_text("")
        self.run_action("reopen")

        calls = self.calls_made()
        create = next(c for c in calls if c[:2] == ["tab", "create"])
        self.assertIn("--workspace", create)
        self.assertEqual(create[create.index("--workspace") + 1], "w5")
        self.assertEqual(create[create.index("--cwd") + 1], "/work/app")
        self.assertEqual(create[create.index("--label") + 1], "herdr-tab-launcher-reopen")

        split = next(c for c in calls if c[:2] == ["pane", "split"])
        self.assertEqual(split[split.index("--direction") + 1], "right")
        self.assertEqual(split[split.index("--ratio") + 1], "0.6")
        self.assertEqual(split[split.index("--cwd") + 1], "/work/app")

        runs = [c for c in calls if c[:2] == ["pane", "run"]]
        self.assertIn("herdr-fresh-pane .", [c[3] for c in runs])
        self.assertTrue(
            any(c[3] == f"{self.pi} --session {self.session}" for c in runs), runs
        )
        self.assertIn(["tab", "rename", "w9:tNEW1", ""], calls)
        self.assertEqual(json.loads(self.stack.read_text()), [])

    def test_reopen_falls_back_when_the_workspace_is_gone(self):
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("closed")
        self.seed([{"tab_id": "w5:t2", "workspace_id": "w5", "label": "5"}],
                  [{"tab_id": "w5:t2", "pane_id": "w5:p3", "cwd": "/work/other"}],
                  workspaces=("w9",))
        self.calls.write_text("")
        self.run_action("reopen")
        create = next(c for c in self.calls_made() if c[:2] == ["tab", "create"])
        self.assertNotIn("--workspace", create)

    def test_reopen_starts_plain_pi_when_the_session_file_is_gone(self):
        self.dev_tab()
        self.run_action("capture")
        self.close_tab("w5:t1")
        self.run_action("closed")
        self.session.unlink()
        self.calls.write_text("")
        self.run_action("reopen")
        runs = [c[3] for c in self.calls_made() if c[:2] == ["pane", "run"]]
        self.assertIn(str(self.pi), runs)
        self.assertFalse(any("--session" in run for run in runs), runs)

    def test_reopen_with_nothing_closed_notifies_and_creates_nothing(self):
        self.dev_tab()
        self.calls.write_text("")
        self.run_action("reopen")
        calls = self.calls_made()
        self.assertFalse([c for c in calls if c[:2] == ["tab", "create"]])
        self.assertEqual(calls, [["notification", "show", "No closed tab to reopen"]])

    def test_stack_keeps_the_most_recent_closes_only(self):
        tabs = [{"tab_id": f"w5:t{n}", "workspace_id": "w5", "label": str(n)}
                for n in range(12)]
        panes = [{"tab_id": f"w5:t{n}", "pane_id": f"w5:p{n}", "cwd": "/w", "agent": ""}
                 for n in range(12)]
        self.seed(tabs, panes)
        for n in range(12):
            self.run_action("capture")
            self.close_tab(f"w5:t{n}")
            self.run_action("closed")
        stack = json.loads(self.stack.read_text())
        self.assertEqual(len(stack), 10)
        self.assertEqual(stack[-1]["tab_id"], "w5:t11")


if __name__ == "__main__":
    unittest.main()
