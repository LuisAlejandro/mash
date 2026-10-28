#!/usr/bin/env python3
"""Local Herdr orchestration records.

Herdr places panes and reports lifecycle. This process owns the Run, Task,
Dispatch, and inbox. A pane going idle does not settle a Task. A wait that
times out does not change a Dispatch. Release closes a pane only after an
accepted worker_done, and only when this Dispatch created that pane.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import secrets
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator


POLL_SECONDS = float(os.environ.get("HERDR_ORCH_POLL_SECONDS", "0.05"))
REUSABLE = {"settled", "retained"}


class OrchestrationError(Exception):
    """A Herdr command failed. The store is left as the last successful write."""

    def __init__(self, message: str, **extra: Any) -> None:
        super().__init__(message)
        self.message = message
        self.extra = extra


def emit(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")


def die(message: str, **extra: Any) -> None:
    payload: dict[str, Any] = {"error": message, **extra}
    json.dump(payload, sys.stderr, indent=2)
    sys.stderr.write("\n")
    raise SystemExit(1)


def require_state() -> Path:
    root = os.environ.get("XDG_STATE_HOME", "")
    # Same boundary as the other Mash helpers: a launch that is not pointed
    # at ~/.mash must not create orchestration records beside the personal
    # Herdr server.
    if "/.mash/" not in root:
        die("Mash state directory is not set")
    path = Path(root) / "mash-orchestration"
    path.mkdir(parents=True, exist_ok=True)
    return path


def store_file() -> Path:
    return require_state() / "store.json"


def empty_store() -> dict[str, Any]:
    return {"seq": 0, "runs": {}, "tasks": {}, "dispatches": {}, "deliveries": []}


def load_store(path: Path) -> dict[str, Any]:
    if not path.exists():
        return empty_store()
    text = path.read_text()
    if not text.strip():
        return empty_store()
    data = json.loads(text)
    data.setdefault("seq", 0)
    data.setdefault("runs", {})
    data.setdefault("tasks", {})
    data.setdefault("dispatches", {})
    data.setdefault("deliveries", [])
    return data


def save_store(path: Path, data: dict[str, Any]) -> None:
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


@contextmanager
def locked() -> Iterator[dict[str, Any]]:
    path = store_file()
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            data = load_store(path)
            yield data
            save_store(path, data)
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def pane_id() -> str:
    pane = os.environ.get("HERDR_PANE_ID", "")
    if not pane:
        die("HERDR_PANE_ID is not set")
    return pane


def require_herdr_env() -> None:
    if os.environ.get("HERDR_ENV") != "1":
        die("HERDR_ENV is not 1")


def next_id(data: dict[str, Any], prefix: str) -> str:
    data["seq"] = int(data["seq"]) + 1
    return f"{prefix}_{data['seq']}"


def run_for_coordinator(data: dict[str, Any], coordinator: str) -> dict[str, Any]:
    runs = [
        run
        for run in data["runs"].values()
        if run["coordinator_pane_id"] == coordinator
    ]
    if not runs:
        die("no run is bound to this pane")
    runs.sort(key=lambda run: run["seq"])
    return runs[-1]


def open_dispatch(data: dict[str, Any], worker_pane: str) -> dict[str, Any] | None:
    found = [
        dispatch
        for dispatch in data["dispatches"].values()
        if dispatch["pane_id"] == worker_pane and dispatch["status"] == "open"
    ]
    if len(found) > 1:
        die("multiple open dispatches for this pane")
    return found[0] if found else None


def dispatch_by_id(data: dict[str, Any], dispatch_id: str) -> dict[str, Any]:
    dispatch = data["dispatches"].get(dispatch_id)
    if dispatch is None:
        die("unknown dispatch", id=dispatch_id)
    return dispatch


def delivery_by_id(data: dict[str, Any], delivery_id: str) -> dict[str, Any]:
    for delivery in data["deliveries"]:
        if delivery["id"] == delivery_id:
            return delivery
    die("unknown delivery", id=delivery_id)


def unacked(data: dict[str, Any], run_id: str) -> list[dict[str, Any]]:
    return [
        delivery
        for delivery in data["deliveries"]
        if delivery["run_id"] == run_id and not delivery["acked"]
    ]


def public_dispatch(dispatch: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": dispatch["id"],
        "run_id": dispatch["run_id"],
        "task_id": dispatch["task_id"],
        "pane_id": dispatch["pane_id"],
        "agent_name": dispatch["agent_name"],
        "session_path": dispatch["session_path"],
        "created_pane": dispatch["created_pane"],
        "status": dispatch["status"],
        "outcome": dispatch["outcome"],
        "summary": dispatch["summary"],
        "retained": dispatch["retained"],
    }


def herdr_bin() -> str:
    return os.environ.get("HERDR_BIN_PATH") or "herdr"


def herdr(*args: str, check: bool = True) -> dict[str, Any]:
    proc = subprocess.run(
        [herdr_bin(), *args],
        capture_output=True,
        text=True,
    )
    payload = parse_json_stdout(proc.stdout) if proc.returncode == 0 else {}
    if check and proc.returncode != 0:
        raise OrchestrationError(
            "herdr command failed",
            command=[*args],
            returncode=proc.returncode,
            stderr=proc.stderr.strip(),
        )
    return payload


def parse_json_stdout(text: str) -> dict[str, Any]:
    text = text.strip()
    if not text:
        return {}
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = None
        for line in reversed(text.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
                break
            except json.JSONDecodeError:
                continue
        if parsed is None:
            die("herdr did not return JSON", stdout=text)
    if not isinstance(parsed, dict):
        die("herdr JSON was not an object")
    return parsed


def split_pane(direction: str) -> str:
    payload = herdr(
        "pane",
        "split",
        "--current",
        "--direction",
        direction,
        "--cwd",
        os.getcwd(),
        "--no-focus",
    )
    pane = ((payload.get("result") or {}).get("pane") or {}).get("pane_id")
    if not isinstance(pane, str) or not pane:
        die("herdr pane split did not return a pane id", payload=payload)
    return pane


def session_path_for(agent_name: str) -> str | None:
    proc = subprocess.run(
        [herdr_bin(), "agent", "get", agent_name],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    result = payload.get("result") or {}
    for key in ("agent_session", "session"):
        block = result.get(key)
        if not isinstance(block, dict):
            continue
        for field in ("path", "agent_session_path"):
            value = block.get(field)
            if isinstance(value, str) and value:
                return value
    return None


def preamble(run_id: str, task_id: str, dispatch_id: str, spec: str) -> str:
    return (
        "You are a dispatched Herdr orchestration worker.\n"
        f"Run: {run_id}\n"
        f"Task: {task_id}\n"
        f"Dispatch: {dispatch_id}\n"
        "\n"
        "Do only this task:\n"
        f"{spec}\n"
        "\n"
        "Questions go to the coordinator through the ask_coordinator tool. "
        "Wait for its reply.\n"
        "Do not call ask_user. Do not answer a question by typing into a pane "
        "with herdr agent send-keys.\n"
        "When the task is finished, run exactly once:\n"
        "mash-orchestration worker-done --outcome succeeded --summary "
        "\"<three sentences: work, findings, remaining>\"\n"
        "Use --outcome failed when the task failed. Then stop. "
        "Idle is not completion.\n"
    )


def submit_preamble(agent_name: str, text: str) -> None:
    # No --wait. That flag settles on idle, and idle is not worker_done.
    herdr("agent", "prompt", agent_name, text)


def create_attempt(
    data: dict[str, Any],
    run: dict[str, Any],
    spec: str,
    worker_pane: str,
    agent_name: str,
    created_pane: bool,
    session_path: str | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    task_id = next_id(data, "task")
    task = {
        "id": task_id,
        "seq": data["seq"],
        "run_id": run["id"],
        "spec": spec,
        "status": "open",
    }
    dispatch_id = next_id(data, "dispatch")
    dispatch = {
        "id": dispatch_id,
        "seq": data["seq"],
        "run_id": run["id"],
        "task_id": task_id,
        "pane_id": worker_pane,
        "agent_name": agent_name,
        "session_path": session_path,
        "created_pane": created_pane,
        "status": "open",
        "outcome": None,
        "summary": None,
        "retained": False,
    }
    data["tasks"][task_id] = task
    data["dispatches"][dispatch_id] = dispatch
    return task, dispatch


def cmd_run_create(objective: str) -> None:
    coordinator = pane_id()
    with locked() as data:
        run_id = next_id(data, "run")
        run = {
            "id": run_id,
            "seq": data["seq"],
            "objective": objective,
            "coordinator_pane_id": coordinator,
        }
        data["runs"][run_id] = run
    emit({"run": run})


def cmd_worker_start(spec: str, direction: str) -> None:
    require_herdr_env()
    coordinator = pane_id()
    with locked() as data:
        run = run_for_coordinator(data, coordinator)
        run_id = run["id"]
    worker_pane = split_pane(direction)
    agent_name = "w" + secrets.token_hex(4)
    try:
        herdr("agent", "start", agent_name, "--kind", "pi", "--pane", worker_pane)
    except OrchestrationError as exc:
        die(
            "agent start failed after the pane was created",
            pane_id=worker_pane,
            agent_name=agent_name,
            cause=exc.message,
        )
    session_path = session_path_for(agent_name)
    with locked() as data:
        run = data["runs"][run_id]
        _task, dispatch = create_attempt(
            data, run, spec, worker_pane, agent_name, True, session_path
        )
        text = preamble(run["id"], dispatch["task_id"], dispatch["id"], spec)
        recorded = public_dispatch(dispatch)
    try:
        submit_preamble(agent_name, text)
    except OrchestrationError as exc:
        die("preamble was not submitted", dispatch=recorded, cause=exc.message)
    emit({"dispatch": recorded, "preamble_submitted": True})


def cmd_reuse(dispatch_id: str, spec: str) -> None:
    require_herdr_env()
    coordinator = pane_id()
    with locked() as data:
        run = run_for_coordinator(data, coordinator)
        previous = dispatch_by_id(data, dispatch_id)
        if previous["run_id"] != run["id"]:
            die("dispatch is not in the bound run")
        if previous["status"] not in REUSABLE:
            die("dispatch is not settled")
        if open_dispatch(data, previous["pane_id"]) is not None:
            die("pane already has an open dispatch")
        _task, dispatch = create_attempt(
            data,
            run,
            spec,
            previous["pane_id"],
            previous["agent_name"],
            False,
            previous["session_path"],
        )
        text = preamble(run["id"], dispatch["task_id"], dispatch["id"], spec)
        recorded = public_dispatch(dispatch)
        agent_name = dispatch["agent_name"]
    try:
        submit_preamble(agent_name, text)
    except OrchestrationError as exc:
        die("preamble was not submitted", dispatch=recorded, cause=exc.message)
    emit({"dispatch": recorded, "preamble_submitted": True})


def cmd_ask(question: str, options: list[str], timeout_ms: int | None, resume: str | None) -> None:
    worker = pane_id()
    if resume:
        message_id = resume
        with locked() as data:
            delivery = delivery_by_id(data, message_id)
            if delivery["type"] != "question":
                die("delivery is not a question", id=message_id)
            dispatch = dispatch_by_id(data, delivery["dispatch_id"])
            if dispatch["pane_id"] != worker or dispatch["status"] != "open":
                die("question does not belong to the open dispatch on this pane")
    else:
        with locked() as data:
            dispatch = open_dispatch(data, worker)
            if dispatch is None:
                die("no open dispatch for this pane")
            message_id = next_id(data, "msg")
            data["deliveries"].append(
                {
                    "id": message_id,
                    "seq": data["seq"],
                    "run_id": dispatch["run_id"],
                    "dispatch_id": dispatch["id"],
                    "type": "question",
                    "acked": False,
                    "reply": None,
                    "body": {"question": question, "options": options},
                }
            )

    # The lock is not held while waiting. A reply has to be written by the
    # coordinator, and a timeout must leave the question pending.
    deadline = None if timeout_ms is None else time.monotonic() + (timeout_ms / 1000)
    while True:
        with locked() as data:
            delivery = delivery_by_id(data, message_id)
            reply = delivery["reply"]
        if reply is not None:
            emit({"id": message_id, "status": "answered", "reply": reply})
            return
        if deadline is not None and time.monotonic() >= deadline:
            emit({"id": message_id, "status": "pending", "reply": None})
            return
        time.sleep(POLL_SECONDS)


def cmd_reply(message_id: str, body: str) -> None:
    coordinator = pane_id()
    with locked() as data:
        run = run_for_coordinator(data, coordinator)
        delivery = delivery_by_id(data, message_id)
        if delivery["run_id"] != run["id"]:
            die("delivery is not in the bound run")
        if delivery["type"] != "question":
            die("delivery is not a question")
        if delivery["reply"] is not None:
            die("question already has a reply")
        delivery["reply"] = body
    emit({"id": message_id, "reply": body})


def cmd_check(wait: bool, types: list[str], timeout_ms: int | None, ack: str | None) -> None:
    coordinator = pane_id()
    with locked() as data:
        run = run_for_coordinator(data, coordinator)
        run_id = run["id"]
        if ack:
            delivery = delivery_by_id(data, ack)
            if delivery["run_id"] != run_id:
                die("delivery is not in the bound run")
            delivery["acked"] = True

    deadline = None if timeout_ms is None else time.monotonic() + (timeout_ms / 1000)
    while True:
        with locked() as data:
            rows = unacked(data, run_id)
        matched = rows
        if types:
            matched = [row for row in rows if row["type"] in types]
        if matched:
            # The type filter decides when a waiter wakes. The batch itself
            # is every unacknowledged delivery, so older mail is not skipped.
            emit({"status": "ok", "deliveries": rows})
            return
        if not wait:
            emit({"status": "ok", "deliveries": rows})
            return
        if deadline is not None and time.monotonic() >= deadline:
            emit({"status": "timeout", "deliveries": []})
            return
        time.sleep(POLL_SECONDS)


def cmd_worker_done(outcome: str, summary: str, files: list[str], report: str | None) -> None:
    worker = pane_id()
    with locked() as data:
        dispatch = open_dispatch(data, worker)
        if dispatch is None:
            existing = [
                item
                for item in data["dispatches"].values()
                if item["pane_id"] == worker and item["status"] in {"settled", "retained", "released"}
            ]
            if existing:
                die("already settled")
            die("no open dispatch for this pane")
        dispatch["status"] = "settled"
        dispatch["outcome"] = outcome
        dispatch["summary"] = summary
        task = data["tasks"][dispatch["task_id"]]
        task["status"] = "settled"
        message_id = next_id(data, "msg")
        delivery = {
            "id": message_id,
            "seq": data["seq"],
            "run_id": dispatch["run_id"],
            "dispatch_id": dispatch["id"],
            "type": "worker_done",
            "acked": False,
            "reply": None,
            "body": {
                "outcome": outcome,
                "summary": summary,
                "files": files,
                "report": report,
            },
        }
        data["deliveries"].append(delivery)
        recorded = public_dispatch(dispatch)
    emit({"dispatch": recorded, "delivery_id": message_id})


def cmd_heartbeat() -> None:
    worker = pane_id()
    with locked() as data:
        dispatch = open_dispatch(data, worker)
        if dispatch is None:
            die("no open dispatch for this pane")
        message_id = next_id(data, "msg")
        data["deliveries"].append(
            {
                "id": message_id,
                "seq": data["seq"],
                "run_id": dispatch["run_id"],
                "dispatch_id": dispatch["id"],
                "type": "heartbeat",
                "acked": False,
                "reply": None,
                "body": {},
            }
        )
    emit({"id": message_id, "type": "heartbeat"})


def owned_settled(data: dict[str, Any], dispatch_id: str, coordinator: str) -> dict[str, Any]:
    run = run_for_coordinator(data, coordinator)
    dispatch = dispatch_by_id(data, dispatch_id)
    if dispatch["run_id"] != run["id"]:
        die("dispatch is not in the bound run")
    if dispatch["status"] not in REUSABLE and dispatch["status"] != "released":
        die("dispatch is not settled")
    return dispatch


def cmd_retain(dispatch_id: str) -> None:
    coordinator = pane_id()
    with locked() as data:
        dispatch = owned_settled(data, dispatch_id, coordinator)
        if dispatch["status"] == "released":
            die("dispatch is not settled")
        dispatch["status"] = "retained"
        dispatch["retained"] = True
        recorded = public_dispatch(dispatch)
    emit({"dispatch": recorded})


def cmd_release(dispatch_id: str) -> None:
    coordinator = pane_id()
    with locked() as data:
        dispatch = owned_settled(data, dispatch_id, coordinator)
        if dispatch["status"] == "released":
            die("dispatch is already released")
        if not dispatch["created_pane"]:
            die("dispatch did not create this pane")
        if open_dispatch(data, dispatch["pane_id"]) is not None:
            die("another open dispatch is using this pane")
        worker_pane = dispatch["pane_id"]
    herdr("pane", "close", worker_pane)
    with locked() as data:
        dispatch = data["dispatches"][dispatch_id]
        dispatch["status"] = "released"
        recorded = public_dispatch(dispatch)
    emit({"dispatch": recorded, "closed_pane": worker_pane})


def cmd_list() -> None:
    coordinator = pane_id()
    with locked() as data:
        run = run_for_coordinator(data, coordinator)
        tasks = [task for task in data["tasks"].values() if task["run_id"] == run["id"]]
        dispatches = [
            public_dispatch(item)
            for item in data["dispatches"].values()
            if item["run_id"] == run["id"]
        ]
        deliveries = unacked(data, run["id"])
    tasks.sort(key=lambda task: task["seq"])
    dispatches.sort(key=lambda item: item["id"])
    emit({"run": run, "tasks": tasks, "dispatches": dispatches, "deliveries": deliveries})


def cmd_dispatch_for_pane(explicit: str | None) -> None:
    worker = explicit or os.environ.get("HERDR_PANE_ID", "")
    if not worker:
        die("HERDR_PANE_ID is not set")
    with locked() as data:
        dispatch = open_dispatch(data, worker)
        recorded = public_dispatch(dispatch) if dispatch else None
    emit({"dispatch": recorded})


def event_pane_id(payload: dict[str, Any]) -> str:
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    if not isinstance(data, dict):
        return ""
    direct = data.get("pane_id")
    if isinstance(direct, str) and direct:
        return direct
    pane = data.get("pane")
    if isinstance(pane, dict):
        for key in ("pane_id", "id"):
            value = pane.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def cmd_pane_exited() -> None:
    raw = os.environ.get("HERDR_PLUGIN_EVENT_JSON", "")
    if not raw.strip():
        emit({"marked": []})
        return
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        die("pane event was not JSON")
    if not isinstance(payload, dict):
        die("pane event was not an object")
    worker = event_pane_id(payload)
    if not worker:
        emit({"marked": []})
        return
    marked: list[str] = []
    with locked() as data:
        for dispatch in data["dispatches"].values():
            if dispatch["pane_id"] != worker or dispatch["status"] != "open":
                continue
            dispatch["status"] = "exited"
            task = data["tasks"].get(dispatch["task_id"])
            if task and task["status"] == "open":
                task["status"] = "exited"
            marked.append(dispatch["id"])
    emit({"marked": marked})


def parse_options(raw: str | None) -> list[str]:
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        die("options are not JSON", detail=str(exc))
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        die("options must be a JSON array of strings")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="mash-orchestration")
    sub = parser.add_subparsers(dest="command", required=True)

    run_create = sub.add_parser("run-create")
    run_create.add_argument("--objective", required=True)

    worker_start = sub.add_parser("worker-start")
    worker_start.add_argument("--spec", required=True)
    worker_start.add_argument("--direction", default="right", choices=("right", "down"))

    reuse = sub.add_parser("reuse")
    reuse.add_argument("--dispatch", required=True)
    reuse.add_argument("--spec", required=True)

    ask = sub.add_parser("ask")
    ask.add_argument("--question", required=True)
    ask.add_argument("--options-json")
    ask.add_argument("--timeout-ms", type=int)
    ask.add_argument("--resume")

    reply = sub.add_parser("reply")
    reply.add_argument("--id", required=True)
    reply.add_argument("--body", required=True)

    check = sub.add_parser("check")
    check.add_argument("--wait", action="store_true")
    check.add_argument("--types", default="")
    check.add_argument("--timeout-ms", type=int)
    check.add_argument("--ack")

    done = sub.add_parser("worker-done")
    done.add_argument("--outcome", required=True, choices=("succeeded", "failed"))
    done.add_argument("--summary", required=True)
    done.add_argument("--files", action="append", default=[])
    done.add_argument("--report")

    sub.add_parser("heartbeat")

    retain = sub.add_parser("retain")
    retain.add_argument("--dispatch", required=True)

    release = sub.add_parser("release")
    release.add_argument("--dispatch", required=True)

    sub.add_parser("list")

    lookup = sub.add_parser("dispatch-for-pane")
    lookup.add_argument("--pane")

    sub.add_parser("pane-exited")
    return parser


def main(argv: list[str]) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        _dispatch(args)
    except OrchestrationError as exc:
        die(exc.message, **exc.extra)


def _dispatch(args: argparse.Namespace) -> None:
    require_state()
    if args.command == "run-create":
        if not args.objective.strip():
            die("objective is empty")
        cmd_run_create(args.objective)
    elif args.command == "worker-start":
        if not args.spec.strip():
            die("spec is empty")
        cmd_worker_start(args.spec, args.direction)
    elif args.command == "reuse":
        if not args.spec.strip():
            die("spec is empty")
        cmd_reuse(args.dispatch, args.spec)
    elif args.command == "ask":
        if not args.question.strip():
            die("question is empty")
        if args.timeout_ms is not None and args.timeout_ms < 0:
            die("timeout is negative")
        cmd_ask(args.question, parse_options(args.options_json), args.timeout_ms, args.resume)
    elif args.command == "reply":
        if not args.body.strip():
            die("reply is empty")
        cmd_reply(args.id, args.body)
    elif args.command == "check":
        types = [item for item in args.types.split(",") if item]
        if args.timeout_ms is not None and args.timeout_ms < 0:
            die("timeout is negative")
        cmd_check(args.wait, types, args.timeout_ms, args.ack)
    elif args.command == "worker-done":
        if not args.summary.strip():
            die("summary is empty")
        cmd_worker_done(args.outcome, args.summary, args.files, args.report)
    elif args.command == "heartbeat":
        cmd_heartbeat()
    elif args.command == "retain":
        cmd_retain(args.dispatch)
    elif args.command == "release":
        cmd_release(args.dispatch)
    elif args.command == "list":
        cmd_list()
    elif args.command == "dispatch-for-pane":
        cmd_dispatch_for_pane(args.pane)
    elif args.command == "pane-exited":
        cmd_pane_exited()
    else:
        die("unknown command")


if __name__ == "__main__":
    main(sys.argv[1:])
