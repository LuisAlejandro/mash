#!/usr/bin/env python3
"""Per-agent backends for forking a conversation from an earlier user message.

Every backend answers the same four questions, so the surrounding Herdr workflow
stays agent-agnostic:

* What is this agent's Herdr kind, display name, and session metadata shape?
* Which user messages can be forked from, oldest first?
* Fork exactly before one of them, and report the new session identity.
* How is that new session opened in a pane?

Pi stores sessions as JSONL paths; a storage-only Node helper uses its SDK.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

HELPER = Path(__file__).resolve().parent.parent / "pi_session.mjs"
HELPER_TIMEOUT_SECONDS = 15


class AgentError(RuntimeError):
    """A backend failure that should be shown to the user as-is."""


@dataclass(frozen=True)
class ForkedSession:
    session_file: str
    selected_text: str


@dataclass(frozen=True)
class Agent:
    """One supported agent's identity and behaviour."""

    kind: str  # Herdr's agent kind, e.g. "pi"
    name: str  # Display name, e.g. "Pi"
    session_kind: str  # Herdr's agent_session.kind, "path" for a transcript file
    executable: str  # CLI name used to start the agent in a pane

    def session_from_pane(self, pane: Mapping[str, Any]) -> str:
        """Validate and return the focused pane's trusted session identity."""
        session = pane.get("agent_session")
        if not isinstance(session, dict) or (
            session.get("agent") != self.kind
            or session.get("kind") != self.session_kind
            or session.get("source") != f"herdr:{self.kind}"
        ):
            raise AgentError(
                f"The focused pane has no trusted {self.name} session from Herdr's "
                f"integration. Run `herdr integration install {self.kind}`, restart "
                f"{self.name}, and retry."
            )
        value = session.get("value")
        return self._as_session_path(value)

    def _as_session_path(self, value: Any) -> str:
        text = value if isinstance(value, str) and value.strip() else None
        if text is None:
            raise self._missing_session()
        path = Path(text)
        if not path.is_absolute() or path.suffix != ".jsonl":
            raise self._missing_session()
        return str(path)

    def _missing_session(self) -> AgentError:
        return AgentError(
            f"Herdr's {self.name} integration reported a missing or malformed session. "
            f"Restart {self.name} and retry."
        )

    def same_session(self, left: str, right: str) -> bool:
        """True when two reported identities refer to the same session."""
        return Path(left).resolve() == Path(right).resolve()

    def launch_args(self, fork_session: str) -> list[str]:
        """Native arguments that open an existing session in a new pane."""
        raise NotImplementedError

    def list_messages(self, session: str) -> list[dict[str, Any]]:
        """Rendered user messages, oldest first, with fork availability."""
        raise NotImplementedError

    def fork(self, session: str, message_id: str) -> ForkedSession:
        """Fork before `message_id`; return the new session and unsent draft."""
        raise NotImplementedError


class PiAgent(Agent):
    """Pi storage only: no second agent process, extension or MCP startup."""

    def __init__(self) -> None:
        super().__init__(kind="pi", name="Pi", session_kind="path", executable="pi")

    def launch_args(self, fork_session: str) -> list[str]:
        return ["--session", fork_session]

    def _candidates(self) -> list[str]:
        """Every `pi` worth inspecting, best first.

        Mash ships a `pi` shim on MASH_BIN ahead of the bundled binary so it can
        animate the wait before the agent starts. That shim is a shell script
        with no package beside it, so resolving only the first PATH hit found no
        runtime at all. Keep looking along MASH_BIN for the copy that does.
        """
        found = [shutil.which(self.executable)]
        found.extend(
            str(Path(directory) / self.executable)
            for directory in os.environ.get("MASH_BIN", "").split(":") if directory
        )
        seen, candidates = set(), []
        for candidate in found:
            if not candidate or candidate in seen or not os.path.isfile(candidate):
                continue
            seen.add(candidate)
            candidates.append(candidate)
        return candidates

    def _runtime(self) -> tuple[Path, Path]:
        executables = self._candidates()
        if not executables:
            raise AgentError("Pi executable not found in PATH.")
        for executable in executables:
            try:
                return self._runtime_for(executable)
            except AgentError:
                continue
        raise AgentError("Cannot resolve bundled Pi SessionManager and Node from the Pi executable.")

    def _runtime_for(self, executable: str) -> tuple[Path, Path]:
        package = node = None
        for parent in Path(executable).resolve().parents:
            manifest = parent / "package.json"
            if package is None and manifest.is_file() and (parent / "dist/index.js").is_file():
                try:
                    if json.loads(manifest.read_text())["name"] == "@earendil-works/pi-coding-agent":
                        package = parent / "dist/index.js"
                except (OSError, ValueError, KeyError):
                    pass
            if node is None and (parent / "bin/node").is_file():
                node = parent / "bin/node"
            if package and node:
                return node, package
        raise AgentError("Cannot resolve bundled Pi SessionManager and Node from the Pi executable.")

    def _call(self, command: str, session: str, *args: str) -> Mapping[str, Any]:
        if not HELPER.is_file():
            raise AgentError(f"Pi session helper is missing: {HELPER}")
        node, module = self._runtime()
        try:
            response = subprocess.run(
                [str(node), str(HELPER), str(module), command, session, *args],
                capture_output=True, text=True, check=True, timeout=HELPER_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as exc:
            raise AgentError(f"Pi session {command} timed out.") from exc
        except subprocess.CalledProcessError as exc:
            raise AgentError((exc.stderr or f"Pi session {command} failed.").strip()) from exc
        except OSError as exc:
            raise AgentError(f"Cannot run Pi session {command}: {exc}") from exc
        try:
            data = json.loads(response.stdout)
            if not isinstance(data, dict):
                raise ValueError("expected an object")
            return data
        except ValueError as exc:
            raise AgentError(f"Pi session {command} helper returned invalid JSON.") from exc

    def list_messages(self, session: str) -> list[dict[str, Any]]:
        entries = self._call("list", session).get("entries")
        if not isinstance(entries, list) or any(
            not isinstance(e, dict) or not isinstance(e.get("id"), str)
            or not isinstance(e.get("text"), str) or not isinstance(e.get("forkable"), bool)
            or e.get("visibility") != "rendered" for e in entries
        ):
            raise AgentError("Pi session list helper returned malformed entries.")
        if not entries:
            raise AgentError("No user messages are present in this session's rendered transcript.")
        return entries

    def fork(self, session: str, message_id: str) -> ForkedSession:
        data = self._call("fork", session, message_id)
        fork = self._as_session_path(data.get("sessionFile"))
        if self.same_session(session, fork) or not Path(fork).is_file():
            raise AgentError("Pi session fork helper did not create a distinct session file.")
        text = data.get("selectedText")
        if not isinstance(text, str):
            raise AgentError("Pi session fork helper returned no draft text.")
        return ForkedSession(fork, text)


AGENTS: dict[str, Agent] = {agent.kind: agent for agent in (PiAgent(),)}
# Named so error messages list what is actually supported instead of one agent.
SUPPORTED_KINDS = tuple(AGENTS)


def agent_for(kind: Any) -> Agent:
    """Resolve a Herdr pane's agent kind to a backend."""
    name = kind if isinstance(kind, str) and kind.strip() else None
    if name is None:
        raise AgentError(
            f"The focused pane has no recognized agent; "
            f"supported: {_name_list()}."
        )
    agent = AGENTS.get(name)
    if agent is None:
        raise AgentError(
            f"The focused pane is {name}; supported: {_name_list()}. "
            f"Focus a supported agent pane and retry."
        )
    return agent


def _name_list() -> str:
    return ", ".join(agent.name for agent in AGENTS.values())
