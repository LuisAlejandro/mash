#!/usr/bin/env python3
"""Minimal Pi RPC client for listing and forking user messages.

Pi's RPC mode is a long-lived subprocess speaking JSONL on stdin/stdout. Two
behaviours drive this design:

* stdin must stay open while a command is in flight. Closing it requests an
  orderly shutdown, so a one-shot pipe exits before the response arrives.
* `fork` creates the branched session in memory and writes the file lazily, so
  the new path comes from `get_state` rather than from watching the directory.
"""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path
from typing import Any, Mapping


RESPONSE_TIMEOUT_SECONDS = 30
SHUTDOWN_TIMEOUT_SECONDS = 10


class PiRpcError(RuntimeError):
    """A Pi RPC transport or command failure."""


class PiRpc:
    """One Pi RPC subprocess opened on an existing session file."""

    def __init__(self, session_file: str, executable: str = "pi") -> None:
        self.session_file = session_file
        self.executable = executable
        self.process: subprocess.Popen[str] | None = None
        self._request_id = 0

    def __enter__(self) -> "PiRpc":
        try:
            self.process = subprocess.Popen(
                [
                    self.executable,
                    "--mode",
                    "rpc",
                    "--session",
                    self.session_file,
                    "--no-tools",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError as exc:
            raise PiRpcError(f"Pi executable not found: {self.executable}") from exc
        return self

    def __exit__(self, *_exc: object) -> None:
        process = self.process
        self.process = None
        if process is None:
            return
        try:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()  # Orderly shutdown; Pi flushes the session.
            process.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()
            try:
                process.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                pass

    def call(self, command: str, **payload: Any) -> Mapping[str, Any]:
        process = self.process
        if process is None or process.stdin is None or process.stdout is None:
            raise PiRpcError("Pi RPC process is not running.")

        self._request_id += 1
        request_id = str(self._request_id)
        record = json.dumps({"id": request_id, "type": command, **payload})
        try:
            process.stdin.write(record + "\n")
            process.stdin.flush()
        except OSError as exc:
            raise PiRpcError(f"Could not send the {command} command to Pi.") from exc

        deadline = time.monotonic() + RESPONSE_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line:
                raise PiRpcError(f"Pi exited before answering {command}.")
            try:
                message = json.loads(line)
            except ValueError:
                continue  # Non-protocol noise; the stream stays authoritative.
            if message.get("type") != "response" or message.get("id") != request_id:
                continue  # Session events and extension UI records interleave.
            if not message.get("success"):
                raise PiRpcError(
                    f"Pi rejected {command}: {message.get('error', 'unknown error')}"
                )
            data = message.get("data")
            return data if isinstance(data, dict) else {}
        raise PiRpcError(f"Pi did not answer {command} within {RESPONSE_TIMEOUT_SECONDS}s.")

    def fork_messages(self) -> list[dict[str, str]]:
        """User messages worth forking, oldest first.

        Pi forks *before* the selected message, so the first user message has no
        history behind it and branches into an empty session. Pi's own
        `createBranchedSession` never persists such a branch, so it is dropped
        here instead of being offered as a choice that silently does nothing.
        """
        data = self.call("get_fork_messages")
        messages = data.get("messages")
        if not isinstance(messages, list):
            raise PiRpcError("Pi returned no forkable message list.")
        result: list[dict[str, str]] = []
        for entry in messages:
            if not isinstance(entry, dict):
                continue
            entry_id = entry.get("entryId")
            text = entry.get("text")
            if isinstance(entry_id, str) and entry_id:
                result.append({"id": entry_id, "text": text if isinstance(text, str) else ""})
        if not result:
            raise PiRpcError("This session has no user message to fork from.")
        forkable = result[1:]
        if not forkable:
            raise PiRpcError(
                "This session has only its first user message, which has no earlier "
                "history to fork from."
            )
        return forkable

    def fork(self, entry_id: str) -> str:
        """Fork before `entry_id` and return the new session file path."""
        data = self.call("fork", entryId=entry_id)
        if data.get("cancelled"):
            raise PiRpcError("A Pi extension cancelled the fork.")
        state = self.call("get_state")
        session_file = state.get("sessionFile")
        if not isinstance(session_file, str) or not session_file:
            raise PiRpcError("Pi forked the session but reported no new session file.")
        if Path(session_file).resolve() == Path(self.session_file).resolve():
            raise PiRpcError("Pi reported the source session file after forking.")
        # Pi persists a branched session as soon as it holds an assistant turn, and
        # opens a missing --session path as a fresh empty session without error.
        # Without this check a phantom path would look like a successful fork.
        if not Path(session_file).is_file():
            raise PiRpcError(
                "Pi reported a forked session that was never written to disk. "
                "The chosen message has no earlier history to fork from."
            )
        return session_file
