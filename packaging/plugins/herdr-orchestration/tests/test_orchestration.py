#!/usr/bin/env python3
"""Store and placement checks against a fake herdr binary."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "orchestration.py"
FAKE = r"""#!/usr/bin/env python3
import json, os, sys
log = os.environ["FAKE_HERDR_LOG"]
with open(log, "a") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
if args[:2] == ["pane", "split"]:
    print(json.dumps({"result": {"pane": {"pane_id": "w1:p2"}}}))
elif args[:2] == ["agent", "start"]:
    print(json.dumps({"result": {"name": args[2]}}))
elif args[:2] == ["agent", "prompt"]:
    print(json.dumps({"result": {"submitted": True}}))
elif args[:2] == ["agent", "get"]:
    print(json.dumps({"result": {"agent_session": {"path": "/tmp/worker.jsonl"}}}))
elif args[:2] == ["pane", "close"]:
    print(json.dumps({"result": {"closed": args[2]}}))
else:
    print(json.dumps({"error": "unexpected", "args": args}), file=sys.stderr)
    raise SystemExit(1)
"""


class OrchestrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state = root / ".mash" / "state"
        self.state.mkdir(parents=True)
        self.log = root / "herdr.log"
        fake = root / "herdr"
        fake.write_text(FAKE)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.base = {
            "XDG_STATE_HOME": str(self.state),
            "HERDR_ENV": "1",
            "HERDR_PANE_ID": "w1:p1",
            "HERDR_BIN_PATH": str(fake),
            "FAKE_HERDR_LOG": str(self.log),
            "HERDR_ORCH_POLL_SECONDS": "0.02",
            "PATH": os.environ.get("PATH", ""),
        }

    def run_cli(self, args: list[str], pane: str | None = None, extra: dict | None = None):
        env = dict(self.base)
        if pane is not None:
            env["HERDR_PANE_ID"] = pane
        if extra:
            env.update(extra)
        proc = subprocess.run(
            [sys_executable(), str(CLI), *args],
            capture_output=True,
            text=True,
            env=env,
        )
        payload = {}
        raw = proc.stdout if proc.returncode == 0 else proc.stderr
        if raw.strip():
            payload = json.loads(raw)
        return proc.returncode, payload

    def calls(self) -> list[list[str]]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def start_worker(self) -> dict:
        code, created = self.run_cli(["run-create", "--objective", "ship the loop"])
        self.assertEqual(code, 0, created)
        code, started = self.run_cli(
            ["worker-start", "--spec", "Add the inbox and stop after worker_done."]
        )
        self.assertEqual(code, 0, started)
        self.assertTrue(started["preamble_submitted"])
        self.assertTrue(started["dispatch"]["created_pane"])
        self.assertEqual(started["dispatch"]["pane_id"], "w1:p2")
        self.assertEqual(started["dispatch"]["status"], "open")
        self.assertEqual(started["dispatch"]["session_path"], "/tmp/worker.jsonl")
        prompt = next(call for call in self.calls() if call[:2] == ["agent", "prompt"])
        self.assertEqual(prompt[:3], ["agent", "prompt", started["dispatch"]["agent_name"]])
        self.assertNotIn("--wait", prompt)
        self.assertIn("ask_coordinator", prompt[3])
        self.assertIn("Do not call ask_user", prompt[3])
        self.assertIn("herdr agent send-keys", prompt[3])
        self.assertEqual(created["run"]["coordinator_pane_id"], "w1:p1")
        return started["dispatch"]

    def test_refuses_state_outside_mash(self) -> None:
        proc = subprocess.run(
            [sys_executable(), str(CLI), "list"],
            capture_output=True,
            text=True,
            env={"XDG_STATE_HOME": "/tmp/not-mash", "HERDR_PANE_ID": "w1:p1", "PATH": "/usr/bin"},
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Mash state directory is not set", proc.stderr)

    def test_worker_start_places_a_sibling_pi(self) -> None:
        dispatch = self.start_worker()
        recorded = self.calls()
        self.assertEqual(recorded[0][:2], ["pane", "split"])
        self.assertIn("--current", recorded[0])
        self.assertIn("--no-focus", recorded[0])
        self.assertEqual(
            recorded[1][:6],
            ["agent", "start", dispatch["agent_name"], "--kind", "pi", "--pane"],
        )

    def test_question_replays_until_ack_and_unblocks_on_reply(self) -> None:
        self.start_worker()
        answered: dict = {}

        def worker() -> None:
            code, payload = self.run_cli(
                ["ask", "--question", "Which file?", "--options-json", '["a.ts","b.ts"]', "--timeout-ms", "3000"],
                pane="w1:p2",
            )
            answered["code"] = code
            answered["payload"] = payload

        thread = threading.Thread(target=worker)
        thread.start()
        delivery_id = ""
        for _ in range(50):
            code, inbox = self.run_cli(["check"])
            self.assertEqual(code, 0, inbox)
            if inbox["deliveries"]:
                delivery_id = inbox["deliveries"][0]["id"]
                break
            time.sleep(0.02)
        self.assertTrue(delivery_id)
        again_code, again = self.run_cli(["check"])
        self.assertEqual(again_code, 0)
        self.assertEqual(again["deliveries"][0]["id"], delivery_id)
        self.assertEqual(again["deliveries"][0]["body"]["options"], ["a.ts", "b.ts"])
        code, reply = self.run_cli(["reply", "--id", delivery_id, "--body", "a.ts"])
        self.assertEqual(code, 0, reply)
        thread.join(4)
        self.assertEqual(answered["code"], 0)
        self.assertEqual(answered["payload"]["status"], "answered")
        self.assertEqual(answered["payload"]["reply"], "a.ts")
        code, acked = self.run_cli(["check", "--ack", delivery_id])
        self.assertEqual(code, 0, acked)
        self.assertEqual(acked["deliveries"], [])

    def test_duplicate_worker_done_is_refused(self) -> None:
        self.start_worker()
        args = ["worker-done", "--outcome", "succeeded", "--summary", "Added the inbox. Tests pass. Nothing left."]
        code, first = self.run_cli(args, pane="w1:p2")
        self.assertEqual(code, 0, first)
        self.assertEqual(first["dispatch"]["status"], "settled")
        code, second = self.run_cli(args, pane="w1:p2")
        self.assertNotEqual(code, 0)
        self.assertEqual(second["error"], "already settled")

    def test_release_closes_only_a_pane_this_dispatch_created(self) -> None:
        first = self.start_worker()
        code, early = self.run_cli(["release", "--dispatch", first["id"]])
        self.assertNotEqual(code, 0)
        self.assertEqual(early["error"], "dispatch is not settled")
        self.assertFalse(any(call[:2] == ["pane", "close"] for call in self.calls()))
        code, done = self.run_cli(
            ["worker-done", "--outcome", "succeeded", "--summary", "Done. Checked. Remaining none."],
            pane="w1:p2",
        )
        self.assertEqual(code, 0, done)
        code, reused = self.run_cli(["reuse", "--dispatch", first["id"], "--spec", "Write the skill."])
        self.assertEqual(code, 0, reused)
        self.assertFalse(reused["dispatch"]["created_pane"])
        self.assertEqual(reused["dispatch"]["pane_id"], "w1:p2")
        code, second_done = self.run_cli(
            ["worker-done", "--outcome", "succeeded", "--summary", "Skill written. Reviewed. Remaining none."],
            pane="w1:p2",
        )
        self.assertEqual(code, 0, second_done)
        code, refused = self.run_cli(["release", "--dispatch", reused["dispatch"]["id"]])
        self.assertNotEqual(code, 0)
        self.assertEqual(refused["error"], "dispatch did not create this pane")
        self.assertFalse(any(call[:2] == ["pane", "close"] for call in self.calls()))
        code, released = self.run_cli(["release", "--dispatch", first["id"]])
        self.assertEqual(code, 0, released)
        self.assertEqual(released["closed_pane"], "w1:p2")
        self.assertIn(["pane", "close", "w1:p2"], self.calls())

    def test_timeout_leaves_an_open_dispatch_alone(self) -> None:
        dispatch = self.start_worker()
        code, waited = self.run_cli(["check", "--wait", "--timeout-ms", "80", "--types", "question,worker_done"])
        self.assertEqual(code, 0, waited)
        self.assertEqual(waited["status"], "timeout")
        self.assertEqual(waited["deliveries"], [])
        code, listed = self.run_cli(["list"])
        self.assertEqual(code, 0, listed)
        found = [item for item in listed["dispatches"] if item["id"] == dispatch["id"]]
        self.assertEqual(found[0]["status"], "open")

    def test_pane_exited_marks_only_an_open_dispatch(self) -> None:
        dispatch = self.start_worker()
        code, marked = self.run_cli(
            ["pane-exited"],
            extra={"HERDR_PLUGIN_EVENT_JSON": json.dumps({"data": {"pane": {"pane_id": "w1:p2"}}})},
        )
        self.assertEqual(code, 0, marked)
        self.assertEqual(marked["marked"], [dispatch["id"]])
        code, listed = self.run_cli(["list"])
        self.assertEqual(listed["dispatches"][0]["status"], "exited")

        code, created = self.run_cli(["run-create", "--objective", "second"])
        self.assertEqual(code, 0, created)
        self.log.write_text("")
        code, started = self.run_cli(["worker-start", "--spec", "Settle first."])
        self.assertEqual(code, 0, started)
        code, done = self.run_cli(
            ["worker-done", "--outcome", "failed", "--summary", "Could not finish. Cause noted. Stopped."],
            pane="w1:p2",
        )
        self.assertEqual(code, 0, done)
        code, marked = self.run_cli(
            ["pane-exited"],
            extra={"HERDR_PLUGIN_EVENT_JSON": json.dumps({"data": {"pane_id": "w1:p2"}})},
        )
        self.assertEqual(code, 0, marked)
        self.assertEqual(marked["marked"], [])
        code, listed = self.run_cli(["list"])
        statuses = {item["id"]: item["status"] for item in listed["dispatches"]}
        self.assertEqual(statuses[started["dispatch"]["id"]], "settled")

    def test_retain_does_not_close_the_pane(self) -> None:
        dispatch = self.start_worker()
        code, done = self.run_cli(
            ["worker-done", "--outcome", "succeeded", "--summary", "Kept. Noted. Remaining none."],
            pane="w1:p2",
        )
        self.assertEqual(code, 0, done)
        code, retained = self.run_cli(["retain", "--dispatch", dispatch["id"]])
        self.assertEqual(code, 0, retained)
        self.assertTrue(retained["dispatch"]["retained"])
        self.assertEqual(retained["dispatch"]["status"], "retained")
        self.assertFalse(any(call[:2] == ["pane", "close"] for call in self.calls()))


def sys_executable() -> str:
    return os.environ.get("PYTHON", "python3")


if __name__ == "__main__":
    unittest.main()
