#!/usr/bin/env python3
"""Per-agent backends for forking a conversation from an earlier user message.

Every backend answers the same four questions, so the surrounding Herdr workflow
stays agent-agnostic:

* What is this agent's Herdr kind, display name, and session metadata shape?
* Which user messages can be forked from, oldest first?
* Fork exactly before one of them, and report the new session identity.
* How is that new session opened in a pane?

Pi stores sessions as JSONL transcript paths and forks over its RPC interface.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))


class AgentError(RuntimeError):
    """A backend failure that should be shown to the user as-is."""


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

    def list_messages(self, session: str) -> list[dict[str, str]]:
        """User messages worth forking, oldest first."""
        raise NotImplementedError

    def fork(self, session: str, message_id: str) -> str:
        """Fork before `message_id`; return the new session identity."""
        raise NotImplementedError


class PiAgent(Agent):
    """Pi: JSONL transcript paths, forked over the RPC interface."""

    def __init__(self) -> None:
        super().__init__(kind="pi", name="Pi", session_kind="path", executable="pi")

    def launch_args(self, fork_session: str) -> list[str]:
        return ["--session", fork_session]

    def list_messages(self, session: str) -> list[dict[str, str]]:
        from pi_rpc import PiRpc, PiRpcError

        try:
            with PiRpc(session, self.executable) as rpc:
                return rpc.fork_messages()
        except PiRpcError as exc:
            raise AgentError(str(exc)) from exc

    def fork(self, session: str, message_id: str) -> str:
        from pi_rpc import PiRpc, PiRpcError

        try:
            with PiRpc(session, self.executable) as rpc:
                return rpc.fork(message_id)
        except PiRpcError as exc:
            raise AgentError(str(exc)) from exc


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
