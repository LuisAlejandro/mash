#!/usr/bin/env python3
"""Fork the focused Herdr agent pane from a chosen earlier user message.

The plugin reads the forkable user messages for whichever agent occupies the
focused pane, asks the user to pick one in a Herdr plugin pane, forks exactly at
that message, and opens the new session in a tab, split pane, or workspace.

The source pane is never resumed, written to, or closed. Pi's session SDK reads
an immutable snapshot and creates a separate branch; the source file is never
rewritten. Pi is the supported agent; any other pane fails explicitly.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from agents import Agent, AgentError, SUPPORTED_KINDS, agent_for  # noqa: E402


PLUGIN_ID = "fork-from-message"
# dev-tab's tab.created hook skips this prefix. Without it, the hook races
# agent start, launching a second pi on the right and typing Fresh's command
# into the forked session in the root pane.
FORK_TAB_SENTINEL = "herdr-tab-launcher-fork"
ACTION_TITLE = "Fork agent from message"
DESTINATIONS = ("tab", "pane", "workspace")
COMMAND_TIMEOUT_SECONDS = 15
START_TIMEOUT_MILLISECONDS = 45_000
START_PROCESS_TIMEOUT_SECONDS = 55
SHELL_READY_TIMEOUT_SECONDS = 8
PICKER_TIMEOUT_SECONDS = 300
POLL_INTERVAL_SECONDS = 0.2


class ForkError(RuntimeError):
    """An actionable workflow failure."""


class ForkCancelled(RuntimeError):
    """The user dismissed the picker."""


@dataclass(frozen=True)
class ForkResult:
    source_pane_id: str
    source_session: str
    fork_pane_id: str
    fork_session: str
    entry_id: str
    agent: str
    destination: str
    workspace_id: str
    tab_id: str
    cwd: str
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True)
class ForkTarget:
    destination: str
    workspace_id: str
    tab_id: str
    pane_id: str


class HerdrClient:
    def __init__(self, executable: str) -> None:
        self.executable = executable

    def _run(self, args: Sequence[str], timeout: float) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [self.executable, *args],
                check=True,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except FileNotFoundError as exc:
            raise ForkError(f"Herdr executable not found: {self.executable}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ForkError(f"Herdr command timed out: {' '.join(args[:3])}") from exc
        except subprocess.CalledProcessError as exc:
            detail = (exc.stderr or exc.stdout or "unknown Herdr error").strip()
            raise ForkError(f"Herdr command failed ({' '.join(args[:3])}): {detail}") from exc

    def ok(self, args: Sequence[str], timeout: float = COMMAND_TIMEOUT_SECONDS) -> None:
        # Herdr's `pane run`/`send-text`/`send-keys` answer with an empty body, so
        # they must not go through json(); only the exit status carries meaning.
        self._run(args, timeout)

    def json(self, args: Sequence[str], timeout: float = COMMAND_TIMEOUT_SECONDS) -> Mapping[str, Any]:
        output = self._run(args, timeout).stdout
        try:
            value = json.loads(output)
        except json.JSONDecodeError as exc:
            raise ForkError(f"Herdr returned invalid JSON for {' '.join(args[:3])}") from exc
        if not isinstance(value, dict):
            raise ForkError(f"Herdr returned an unexpected response for {' '.join(args[:3])}")
        return value


def _object(value: Any, description: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ForkError(f"Herdr response is missing {description}")
    return value


def _nonempty_string(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def load_invocation_context(env: Mapping[str, str]) -> Mapping[str, Any]:
    raw = env.get("HERDR_PLUGIN_CONTEXT_JSON")
    if not raw:
        raise ForkError(
            "Herdr did not provide focused-pane context. Invoke this through the installed plugin action."
        )
    try:
        context = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ForkError("Herdr provided malformed focused-pane context.") from exc
    return _object(context, "plugin invocation context")


def _source_details(
    context: Mapping[str, Any], pane: Mapping[str, Any]
) -> tuple[str, str, str, str, Agent]:
    pane_id = _nonempty_string(context.get("focused_pane_id"))
    if pane_id is None:
        raise ForkError(f"No focused pane was available. Focus a {_supported()} pane and try again.")

    if _nonempty_string(pane.get("pane_id")) != pane_id:
        raise ForkError(
            "The focused pane changed before it could be verified. Retry the action."
        )

    try:
        agent = agent_for(pane.get("agent"))
        source_session = agent.session_from_pane(pane)
    except AgentError as exc:
        raise ForkError(str(exc)) from exc

    workspace_id = _nonempty_string(pane.get("workspace_id"))
    if workspace_id is None or workspace_id != _nonempty_string(context.get("workspace_id")):
        raise ForkError(
            "The focused pane's workspace changed before it could be verified. Retry the action."
        )

    cwd = (
        _nonempty_string(context.get("focused_pane_cwd"))
        or _nonempty_string(pane.get("foreground_cwd"))
        or _nonempty_string(pane.get("cwd"))
    )
    if cwd is None or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ForkError(f"The focused {agent.name} pane has no usable working directory.")

    return pane_id, source_session, workspace_id, cwd, agent


def _supported() -> str:
    return " or ".join(SUPPORTED_KINDS)


def _fork_label(context: Mapping[str, Any]) -> str:
    source = _nonempty_string(context.get("tab_label"))
    if source:
        return f"Fork · {' '.join(source.split())}"[:80]
    return "Agent fork"


class ForkWorkflow:
    def __init__(
        self,
        client: HerdrClient,
        context: Mapping[str, Any],
        destination: str = "tab",
    ) -> None:
        if destination not in DESTINATIONS:
            raise ForkError(f"Unsupported fork destination: {destination}")
        self.client = client
        self.context = context
        self.destination = destination
        self.created_resource: tuple[str, str] | None = None
        self.created_session: str | None = None
        self.cleanup_error: str | None = None

    def execute(self) -> ForkResult:
        try:
            return self._execute()
        except ForkCancelled:
            self._cleanup()
            raise
        except Exception as exc:
            self._cleanup()
            message = str(exc) if isinstance(exc, ForkError) else f"Unexpected workflow error: {exc}"
            if self.cleanup_error:
                message = f"{message} {self.cleanup_error}"
            raise ForkError(message) from exc

    def _execute(self) -> ForkResult:
        source_pane_id = _nonempty_string(self.context.get("focused_pane_id"))
        if source_pane_id is None:
            raise ForkError("No focused pane was available. Focus a supported agent pane and try again.")

        pane_response = self.client.json(["pane", "get", source_pane_id])
        pane = _object(_object(pane_response.get("result"), "pane result").get("pane"), "pane data")
        source_pane_id, source_session, workspace_id, cwd, agent = _source_details(
            self.context, pane
        )

        # Read storage without booting a second agent on the source session.
        try:
            messages = agent.list_messages(source_session)
        except AgentError as exc:
            raise ForkError(str(exc)) from exc
        entry_id = self._choose_message(messages, source_pane_id, agent)
        chosen = next((m for m in messages if m.get("id") == entry_id), None)
        if chosen is None or chosen.get("forkable") is False:
            raise ForkError("The picker returned an unavailable message. Retry the action.")
        _notify(self.client, "Forking session", "Creating a branch before the selected message…")
        try:
            branch = agent.fork(source_session, entry_id)
        except AgentError as exc:
            raise ForkError(str(exc)) from exc
        fork_session = branch.session_file
        if agent.same_session(source_session, fork_session):
            raise ForkError("The backend returned the source session instead of a fork.")
        self.created_session = fork_session
        target = self._create_target(source_pane_id, workspace_id, cwd)
        self._focus_target(target)
        _notify(self.client, "Starting fork", "Waiting for Pi to be ready before restoring the unsent draft…")
        self._start_fork_agent(target.pane_id, fork_session, agent)
        self._verify_fork_session(target.pane_id, fork_session, agent)
        self.client.json(["agent", "focus", target.pane_id])
        if target.destination == "tab":
            # Clear the launch label instead of naming the tab. Tab names belong to
            # herdr.auto-title, which names an unnamed tab after the work inside it
            # -- and claims any label another process writes as the user's own
            # rename, locked for good. The "Fork · <source>" name set here froze
            # both the title and the position number, so it was retired in favour
            # of the same clear the launcher scripts do (herdr-new-pi-tab).
            self.client.json(["tab", "rename", target.tab_id, ""])

        # From here the fork is usable. A paste failure must never tear it down.
        self.created_resource = None
        self.created_session = None
        warnings = self._restore_draft(target.pane_id, branch.selected_text)

        result = ForkResult(
            source_pane_id=source_pane_id,
            source_session=source_session,
            fork_pane_id=target.pane_id,
            fork_session=fork_session,
            entry_id=entry_id,
            agent=agent.kind,
            destination=target.destination,
            workspace_id=target.workspace_id,
            tab_id=target.tab_id,
            cwd=cwd,
            warnings=warnings,
        )
        return result

    def _choose_message(
        self, messages: Sequence[Mapping[str, Any]], source_pane_id: str, agent: Agent
    ) -> str:
        """Render the picker in a Herdr plugin pane and wait for a selection.

        The picker splits from the source pane rather than using an overlay:
        overlay and popup plugin panes always target the active pane, so an
        overlay would open over whatever the user is working in instead of over
        the session being forked.
        """
        with tempfile.TemporaryDirectory(prefix="herdr-fork-") as workdir:
            request_path = Path(workdir) / "request.json"
            result_path = Path(workdir) / "result.json"
            request_path.write_text(
                json.dumps(
                    {
                        "messages": list(messages),
                        "result": str(result_path),
                        "title": f"Fork {agent.name} from Message",
                    }
                )
            )
            response = self.client.json(
                [
                    "plugin",
                    "pane",
                    "open",
                    "--plugin",
                    PLUGIN_ID,
                    "--entrypoint",
                    "picker",
                    "--placement",
                    "split",
                    "--target-pane",
                    source_pane_id,
                    "--direction",
                    "down",
                    "--env",
                    f"HERDR_FORK_REQUEST={request_path}",
                    "--focus",
                ]
            )
            pane = _object(
                _object(
                    _object(response.get("result"), "plugin pane result").get("plugin_pane"),
                    "plugin pane",
                ).get("pane"),
                "picker pane",
            )
            picker_pane_id = _nonempty_string(pane.get("pane_id"))
            if picker_pane_id is None:
                raise ForkError("Herdr opened the picker but did not return its pane ID.")

            entry_id = self._wait_for_choice(picker_pane_id, result_path)
            if entry_id is None:
                raise ForkCancelled("No message was chosen.")
            return entry_id

    def _wait_for_choice(self, picker_pane_id: str, result_path: Path) -> str | None:
        """Poll until the picker writes a choice or its pane disappears."""
        deadline = time.monotonic() + PICKER_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if result_path.is_file():
                try:
                    chosen = json.loads(result_path.read_text()).get("id")
                except (OSError, ValueError):
                    chosen = None
                return _nonempty_string(chosen)
            if not self._pane_exists(picker_pane_id):
                # The pane closes itself when the picker exits; a missing result
                # after that means the user cancelled.
                if result_path.is_file():
                    continue
                return None
            time.sleep(POLL_INTERVAL_SECONDS)
        self._close_picker(picker_pane_id)
        raise ForkError("The message picker timed out with no selection.")

    def _pane_exists(self, pane_id: str) -> bool:
        try:
            self.client.json(["pane", "get", pane_id])
        except ForkError:
            return False
        return True

    def _close_picker(self, pane_id: str) -> None:
        try:
            self.client.json(["plugin", "pane", "close", pane_id])
        except ForkError:
            pass

    def _create_target(self, source_pane_id: str, workspace_id: str, cwd: str) -> ForkTarget:
        if self.destination == "pane":
            return self._create_pane_target(source_pane_id, workspace_id, cwd)
        if self.destination == "workspace":
            return self._create_workspace_target(cwd)
        return self._create_tab_target(workspace_id, cwd)

    def _create_tab_target(self, workspace_id: str, cwd: str) -> ForkTarget:
        # tab.created hooks run asynchronously. The sentinel is in the event
        # payload before the hook starts, so dev-tab skips this tab even if its
        # shell is still starting. A later pane-count check alone cannot stop
        # the hook from racing agent start in the root pane.
        response = self.client.json(
            [
                "tab",
                "create",
                "--workspace",
                workspace_id,
                "--cwd",
                cwd,
                "--label",
                FORK_TAB_SENTINEL,
                "--no-focus",
            ]
        )
        result = _object(response.get("result"), "tab creation result")
        tab = _object(result.get("tab"), "created tab")
        root_pane = _object(result.get("root_pane"), "created root pane")
        tab_id = _nonempty_string(tab.get("tab_id"))
        if tab_id is not None:
            self.created_resource = ("tab", tab_id)
        left_pane_id = _nonempty_string(root_pane.get("pane_id"))
        if tab_id is None or left_pane_id is None:
            raise ForkError("Herdr created a tab but did not return its tab and pane IDs.")

        # Own the layout: Fresh runs in the root pane, while agent start must
        # target the new RIGHT pane. --ratio is the existing pane's share, as
        # with herdr-dev-tab-fill. Neither operation focuses the new tab.
        response = self.client.json(
            [
                "pane", "split", left_pane_id, "--direction", "right",
                "--ratio", "0.6", "--cwd", cwd, "--no-focus",
            ]
        )
        right_pane = _object(
            _object(response.get("result"), "pane split result").get("pane"), "right pane"
        )
        right_pane_id = _nonempty_string(right_pane.get("pane_id"))
        if right_pane_id is None or right_pane_id == left_pane_id:
            raise ForkError("Herdr split the fork tab but did not return a distinct right pane.")
        # The trailing '.' makes Fresh show the directory's file explorer.
        self.client.ok(["pane", "run", left_pane_id, "herdr-fresh-pane ."])
        return ForkTarget("tab", workspace_id, tab_id, right_pane_id)

    def _split_direction(self, source_pane_id: str) -> str:
        response = self.client.json(["pane", "layout", "--pane", source_pane_id])
        layout = _object(_object(response.get("result"), "layout result").get("layout"), "layout")
        panes = layout.get("panes")
        if not isinstance(panes, list):
            raise ForkError("Herdr did not return source pane geometry.")
        for pane in panes:
            if not isinstance(pane, dict) or pane.get("pane_id") != source_pane_id:
                continue
            rect = pane.get("rect")
            if not isinstance(rect, dict):
                break
            width = rect.get("width")
            height = rect.get("height")
            if isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0:
                return "right" if width >= height * 2 else "down"
            break
        raise ForkError("Herdr did not return usable source pane geometry.")

    def _create_pane_target(self, source_pane_id: str, workspace_id: str, cwd: str) -> ForkTarget:
        direction = self._split_direction(source_pane_id)
        response = self.client.json(
            [
                "pane",
                "split",
                source_pane_id,
                "--direction",
                direction,
                "--cwd",
                cwd,
                "--focus",
            ]
        )
        pane = _object(_object(response.get("result"), "pane split result").get("pane"), "pane")
        pane_id = _nonempty_string(pane.get("pane_id"))
        if pane_id is not None:
            self.created_resource = ("pane", pane_id)
        tab_id = _nonempty_string(pane.get("tab_id")) or _nonempty_string(self.context.get("tab_id"))
        actual_workspace_id = _nonempty_string(pane.get("workspace_id")) or workspace_id
        if pane_id is None or tab_id is None:
            raise ForkError("Herdr split a pane but did not return its pane and tab IDs.")
        return ForkTarget("pane", actual_workspace_id, tab_id, pane_id)

    def _create_workspace_target(self, cwd: str) -> ForkTarget:
        response = self.client.json(
            [
                "workspace",
                "create",
                "--cwd",
                cwd,
                "--label",
                _fork_label(self.context),
                "--no-focus",
            ]
        )
        result = _object(response.get("result"), "workspace creation result")
        workspace = _object(result.get("workspace"), "created workspace")
        workspace_id = _nonempty_string(workspace.get("workspace_id"))
        if workspace_id is not None:
            self.created_resource = ("workspace", workspace_id)
        tab = _object(result.get("tab"), "created workspace tab")
        root_pane = _object(result.get("root_pane"), "created workspace pane")
        tab_id = _nonempty_string(tab.get("tab_id"))
        pane_id = _nonempty_string(root_pane.get("pane_id"))
        if workspace_id is None or tab_id is None or pane_id is None:
            raise ForkError(
                "Herdr created a workspace but did not return its workspace, tab, and pane IDs."
            )
        return ForkTarget("workspace", workspace_id, tab_id, pane_id)

    def _focus_target(self, target: ForkTarget) -> None:
        if target.destination == "pane":
            return  # The split was focused at creation; it is not an agent yet.
        if target.destination == "workspace":
            self.client.json(["workspace", "focus", target.workspace_id])
        else:
            self.client.json(["tab", "focus", target.tab_id])

    def _start_fork_agent(self, pane_id: str, fork_session: str, agent: Agent) -> None:
        args = [
            "agent",
            "start",
            f"{agent.kind}_fork_{uuid.uuid4().hex[:12]}",
            "--kind",
            agent.kind,
            "--pane",
            pane_id,
            "--timeout",
            str(START_TIMEOUT_MILLISECONDS),
            "--",
            *agent.launch_args(fork_session),
        ]
        deadline = time.monotonic() + SHELL_READY_TIMEOUT_SECONDS
        while True:
            try:
                self.client.json(args, timeout=START_PROCESS_TIMEOUT_SECONDS)
                return
            except ForkError as exc:
                if "agent_pane_busy" not in str(exc) or time.monotonic() >= deadline:
                    raise
                time.sleep(POLL_INTERVAL_SECONDS)

    def _verify_fork_session(self, pane_id: str, fork_session: str, agent: Agent) -> None:
        response = self.client.json(["agent", "get", pane_id])
        agent_data = _object(
            _object(response.get("result"), "agent result").get("agent"), "agent data"
        )
        if agent_data.get("interactive_ready") is not True:
            raise ForkError("The destination agent is no longer interactively ready; no draft was sent.")
        session = agent_data.get("agent_session")
        reported = _nonempty_string(session.get("value")) if isinstance(session, dict) else None
        if reported is None:
            raise ForkError("The destination did not report its session identity; no draft was sent.")
        if not agent.same_session(reported, fork_session):
            raise ForkError(
                f"The new pane opened {reported} instead of the forked session."
            )

    def _restore_draft(self, pane_id: str, text: str) -> tuple[str, ...]:
        if not text:
            return ()
        try:
            # Never let a stored terminal escape end bracketed paste or trigger keys.
            if any(ord(ch) < 32 and ch not in "\n\t" or ord(ch) == 127 for ch in text):
                raise ForkError("Draft contains terminal control characters; paste skipped for safety.")
            # No "--": Herdr takes the text operand literally, so a separate
            # terminator would be pasted into the editor.
            self.client.ok(["pane", "send-text", pane_id, text])
        except (ForkError, OSError, ValueError) as exc:
            warning = f"Fork opened, but the draft could not be restored: {exc}"
            _notify(self.client, "Fork draft not restored", warning)
            print(warning, file=sys.stderr)
            return (warning,)
        return ()

    def _cleanup(self) -> None:
        resource = self.created_resource
        try:
            if resource is not None:
                kind, resource_id = resource
                self.client.json([kind, "close", resource_id])
            if self.created_session is not None:
                Path(self.created_session).unlink(missing_ok=True)
        except Exception as exc:
            # Keep the file when closing a pane fails: it may still be running.
            self.cleanup_error = f"Could not remove incomplete fork: {exc}. Close it manually."
        finally:
            self.created_resource = None
            self.created_session = None


def _herdr_executable(env: Mapping[str, str]) -> str:
    configured = _nonempty_string(env.get("HERDR_BIN_PATH"))
    if configured:
        return configured
    discovered = shutil.which("herdr")
    if discovered:
        return discovered
    raise ForkError("Herdr is not available in PATH and HERDR_BIN_PATH was not provided.")


def _notify(client: HerdrClient, title: str, message: str) -> None:
    try:
        client.json(["notification", "show", title, "--body", message])
    except Exception:
        pass  # Feedback must not become a fork failure.


def _notify_failure(client: HerdrClient, message: str) -> None:
    body = f"{message} Logs: herdr plugin log list --plugin {PLUGIN_ID} --limit 5"
    try:
        client.json(
            [
                "notification",
                "show",
                f"{ACTION_TITLE} failed",
                "--body",
                body,
                "--sound",
                "request",
            ]
        )
    except Exception:
        pass


def run(env: Mapping[str, str], destination: str = "tab") -> ForkResult:
    if env.get("HERDR_ENV") != "1":
        raise ForkError("This action must run inside a Herdr-managed session.")
    client = HerdrClient(_herdr_executable(env))
    try:
        return ForkWorkflow(
            client,
            load_invocation_context(env),
            destination=destination,
        ).execute()
    except ForkError as exc:
        _notify_failure(client, str(exc))
        raise


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=ACTION_TITLE)
    parser.add_argument("--destination", choices=DESTINATIONS, default="tab")
    args = parser.parse_args(argv)
    try:
        result = run(os.environ, destination=args.destination)
    except ForkCancelled:
        print(json.dumps({"status": "cancelled"}))
        return 0
    except ForkError as exc:
        print(f"{ACTION_TITLE} failed: {exc}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "status": "ok",
                "agent": result.agent,
                "tab_id": result.tab_id,
                "pane_id": result.fork_pane_id,
                "source_session": result.source_session,
                "fork_session": result.fork_session,
                "entry_id": result.entry_id,
                "destination": result.destination,
                "workspace_id": result.workspace_id,
                "cwd": result.cwd,
                "warnings": list(result.warnings),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
