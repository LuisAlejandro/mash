#!/usr/bin/env python3
"""Self-check for the merged fork workflow against a fake Herdr CLI and agents."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import fork_from_message as ffm  # noqa: E402
import picker  # noqa: E402
from agents import AgentError, agent_for  # noqa: E402


SOURCE_PANE = "w1:p1"
FRESH_PANE = "w1:p2"
FORK_PANE = "w1:p3"
PICKER_PANE = "w1:p9"
PI_SOURCE = "/tmp/sessions/source.jsonl"
PI_FORK = "/tmp/sessions/fork.jsonl"
OC_SOURCE = "ses_source000000000000000000"
OC_FORK = "ses_fork00000000000000000000"


class FakeAgent:
    """Records the fork leg and stands in for a real backend."""

    def __init__(self, kind, session_kind, name, fork_session, messages=None, fail=None):
        self.kind = kind
        self.session_kind = session_kind
        self.name = name
        self.executable = kind
        self.fork_session = fork_session
        self.messages = messages or [{"id": "e2", "text": "second"}, {"id": "e3", "text": "third"}]
        self.fail = fail
        self.calls: list[tuple] = []

    def session_from_pane(self, pane):
        if self.fail:
            raise AgentError(self.fail)
        return pane["agent_session"]["value"]

    def same_session(self, left, right):
        return str(left) == str(right)

    def launch_args(self, fork_session):
        return ["--session", fork_session]

    def list_messages(self, session):
        self.calls.append(("list", session))
        return list(self.messages)

    def fork(self, session, message_id):
        self.calls.append(("fork", session, message_id))
        return self.fork_session


class FakeClient:
    def __init__(self, tmp: Path, *, choice: str | None, agent_kind: str, source_session: str,
                 reported: str | None = None, fail_on: tuple[str, ...] = ()):
        self.calls: list[list[str]] = []
        self.tmp = tmp
        self.choice = choice
        self.agent_kind = agent_kind
        self.source_session = source_session
        self.reported = reported
        self.fail_on = fail_on
        self.picker_alive = True

    def _session(self, value):
        kind = "path" if self.agent_kind == "pi" else "id"
        return {"agent": self.agent_kind, "kind": kind,
                "source": f"herdr:{self.agent_kind}", "value": value}

    def json(self, args, timeout=None):
        self.calls.append(list(args))
        if self.fail_on and tuple(args[:len(self.fail_on)]) == self.fail_on:
            raise ffm.ForkError("simulated Herdr failure")
        head = " ".join(args[:2])
        if head == "pane get":
            if args[2] == PICKER_PANE:
                if not self.picker_alive:
                    raise ffm.ForkError("pane not found")
                return {"result": {"pane": {"pane_id": PICKER_PANE}}}
            return {
                "result": {
                    "pane": {
                        "pane_id": SOURCE_PANE,
                        "agent": self.agent_kind,
                        "agent_session": self._session(self.source_session),
                        "workspace_id": "w1",
                        "cwd": str(self.tmp),
                    }
                }
            }
        if head == "plugin pane":
            request = next(a.split("=", 1)[1] for a in args if a.startswith("HERDR_FORK_REQUEST="))
            payload = json.loads(Path(request).read_text())
            if self.choice is not None:
                Path(payload["result"]).write_text(json.dumps({"id": self.choice}))
            self.picker_alive = False
            return {"result": {"plugin_pane": {"pane": {"pane_id": PICKER_PANE}}}}
        if head == "tab create":
            return {"result": {"tab": {"tab_id": "w1:t2"}, "root_pane": {"pane_id": FRESH_PANE}}}
        if head == "pane split":
            return {"result": {"pane": {"pane_id": FORK_PANE}}}
        if head == "agent get":
            value = self.reported if self.reported is not None else self.source_session
            return {"result": {"agent": {"agent_session": self._session(value)}}}
        return {"result": {"type": "ok"}}


def _context(tmp: Path) -> dict:
    return {
        "focused_pane_id": SOURCE_PANE,
        "workspace_id": "w1",
        "focused_pane_cwd": str(tmp),
        "tab_label": "agent - work",
    }


def _wire(monkeypatch_agent):
    """Make agent_for() resolve to the fake backend."""
    original = ffm.agent_for
    ffm.agent_for = lambda kind: monkeypatch_agent
    return original


def assert_fork_tab_layout(client: FakeClient, session: str) -> None:
    """The tab.created hook must not launch its own fresh + empty pi."""
    calls = client.calls
    created = next(c for c in calls if c[:2] == ["tab", "create"])
    assert created[created.index("--label") + 1] == ffm.FORK_TAB_SENTINEL, created
    assert created[-1] == "--no-focus", created
    split = next(c for c in calls if c[:2] == ["pane", "split"])
    assert split[:3] == ["pane", "split", FRESH_PANE], split
    assert split[split.index("--direction") + 1] == "right", split
    assert split[split.index("--ratio") + 1] == "0.6", split
    assert split[-1] == "--no-focus", split
    run = next(c for c in calls if c[:2] == ["pane", "run"])
    assert run == ["pane", "run", FRESH_PANE, "herdr-fresh-pane ."], run
    start = next(c for c in calls if c[:2] == ["agent", "start"])
    assert start[start.index("--pane") + 1] == FORK_PANE, start
    assert start[-2:] == ["--session", session], start
    assert len([c for c in calls if c[:2] == ["agent", "start"]]) == 1, calls
    assert calls.index(run) < calls.index(start) < calls.index(["agent", "get", FORK_PANE]), calls
    assert calls[-2:] == [
        ["tab", "rename", "w1:t2", "Fork · agent - work"],
        ["tab", "focus", "w1:t2"],
    ], calls


def test_pi_backend(tmp: Path) -> None:
    agent = FakeAgent("pi", "path", "Pi", PI_FORK)
    client = FakeClient(tmp, choice="e3", agent_kind="pi", source_session=PI_SOURCE,
                        reported=PI_FORK)
    original = _wire(agent)
    try:
        result = ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    finally:
        ffm.agent_for = original

    assert result.agent == "pi", result
    assert result.entry_id == "e3", result
    assert result.fork_session == PI_FORK, result
    assert agent.calls == [("list", PI_SOURCE), ("fork", PI_SOURCE, "e3")], agent.calls
    start = next(c for c in client.calls if c[:2] == ["agent", "start"])
    assert start[2].startswith("pi_fork_"), start
    assert start[start.index("--kind") + 1] == "pi", start
    assert start[start.index("--pane") + 1] == FORK_PANE, start
    assert start[-2:] == ["--session", PI_FORK], start
    assert_fork_tab_layout(client, PI_FORK)


def test_opencode_backend(tmp: Path) -> None:
    agent = FakeAgent("opencode", "id", "OpenCode", OC_FORK)
    client = FakeClient(tmp, choice="msg_c", agent_kind="opencode", source_session=OC_SOURCE,
                        reported=OC_FORK)
    agent.messages = [{"id": "msg_b", "text": "b"}, {"id": "msg_c", "text": "c"}]
    original = _wire(agent)
    try:
        result = ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    finally:
        ffm.agent_for = original

    assert result.agent == "opencode", result
    assert agent.calls == [("list", OC_SOURCE), ("fork", OC_SOURCE, "msg_c")], agent.calls
    start = next(c for c in client.calls if c[:2] == ["agent", "start"])
    assert start[2].startswith("opencode_fork_"), start
    assert start[start.index("--kind") + 1] == "opencode", start
    assert start[start.index("--pane") + 1] == FORK_PANE, start
    assert start[-2:] == ["--session", OC_FORK], start
    assert_fork_tab_layout(client, OC_FORK)


def test_source_pane_never_touched(tmp: Path) -> None:
    for kind, source, fork in (("pi", PI_SOURCE, PI_FORK), ("opencode", OC_SOURCE, OC_FORK)):
        agent = FakeAgent(kind, "path" if kind == "pi" else "id", kind, fork)
        client = FakeClient(tmp, choice="e2", agent_kind=kind, source_session=source,
                            reported=fork)
        original = _wire(agent)
        try:
            ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
        finally:
            ffm.agent_for = original
        assert not any(
            c[:2] in (["agent", "prompt"], ["agent", "send-keys"]) for c in client.calls
        ), (kind, client.calls)
        start = next(c for c in client.calls if c[:2] == ["agent", "start"])
        assert source not in start, (kind, start)
        assert ["tab", "close", "w1:t2"] not in client.calls, (kind, client.calls)


def test_picker_splits_from_source_pane(tmp: Path) -> None:
    agent = FakeAgent("pi", "path", "Pi", PI_FORK)
    client = FakeClient(tmp, choice="e2", agent_kind="pi", source_session=PI_SOURCE,
                        reported=PI_FORK)
    original = _wire(agent)
    try:
        ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    finally:
        ffm.agent_for = original
    call = next(c for c in client.calls if c[:2] == ["plugin", "pane"])
    assert call[call.index("--placement") + 1] == "split", call
    assert call[call.index("--target-pane") + 1] == SOURCE_PANE, call


def test_fork_label_skips_the_actual_dev_tab_event_hook(tmp: Path) -> None:
    """Check the real hook, not a duplicate filter in the fake client."""
    hook = Path(__file__).resolve().parents[2] / "dev-tab" / "dev-tab.sh"
    calls = tmp / "herdr-calls"
    herdr = tmp / "herdr"
    herdr.write_text(f"#!/bin/sh\nprintf 'called\\n' >> '{calls}'\nexit 1\n")
    herdr.chmod(0o755)
    event = {"data": {"tab": {"tab_id": "w1:t2", "label": ffm.FORK_TAB_SENTINEL, "pane_count": 1}}}
    env = {**os.environ, "HERDR_PLUGIN_EVENT_JSON": json.dumps(event), "HERDR_BIN_PATH": str(herdr)}
    result = subprocess.run(["bash", str(hook)], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not calls.exists(), "dev-tab touched a fork tab despite its sentinel label"
    # Control: a regular one-pane tab should reach the hook's pane lookup.
    event["data"]["tab"]["label"] = "Fork · agent - work"
    env["HERDR_PLUGIN_EVENT_JSON"] = json.dumps(event)
    subprocess.run(["bash", str(hook)], env=env, capture_output=True, text=True)
    assert calls.exists(), "the hook stopped processing all tabs; the test is vacuous"


def test_failed_fork_layout_closes_incomplete_tab(tmp: Path) -> None:
    for command in (("pane", "split"), ("pane", "run")):
        agent = FakeAgent("pi", "path", "Pi", PI_FORK)
        client = FakeClient(tmp, choice="e2", agent_kind="pi", source_session=PI_SOURCE,
                            fail_on=command)
        original = _wire(agent)
        try:
            ffm.ForkWorkflow(client, _context(tmp)).execute()
        except ffm.ForkError as exc:
            assert "simulated Herdr failure" in str(exc), exc
        else:
            raise AssertionError("expected ForkError")
        finally:
            ffm.agent_for = original
        assert ["tab", "close", "w1:t2"] in client.calls, client.calls
        assert not any(c[:2] == ["agent", "start"] for c in client.calls), client.calls


def test_cancel_creates_no_destination(tmp: Path) -> None:
    agent = FakeAgent("pi", "path", "Pi", PI_FORK)
    client = FakeClient(tmp, choice=None, agent_kind="pi", source_session=PI_SOURCE,
                        reported=PI_FORK)
    original = _wire(agent)
    try:
        ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    except ffm.ForkCancelled:
        pass
    else:
        raise AssertionError("expected ForkCancelled")
    finally:
        ffm.agent_for = original
    assert not any(c[:2] == ["agent", "start"] for c in client.calls), client.calls
    assert not any(c[:2] == ["tab", "create"] for c in client.calls), client.calls
    assert agent.calls == [("list", PI_SOURCE)], agent.calls


def test_wrong_session_in_new_pane_is_rejected(tmp: Path) -> None:
    agent = FakeAgent("pi", "path", "Pi", PI_FORK)
    client = FakeClient(tmp, choice="e2", agent_kind="pi", source_session=PI_SOURCE,
                        reported=PI_SOURCE)
    original = _wire(agent)
    try:
        ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    except ffm.ForkError as exc:
        assert "instead of the forked session" in str(exc), exc
    else:
        raise AssertionError("expected ForkError")
    finally:
        ffm.agent_for = original
    assert ["tab", "close", "w1:t2"] in client.calls, client.calls


def test_backend_failure_closes_destination(tmp: Path) -> None:
    agent = FakeAgent("pi", "path", "Pi", PI_FORK, fail="no trusted session")
    client = FakeClient(tmp, choice="e2", agent_kind="pi", source_session=PI_SOURCE,
                        reported=PI_FORK)
    original = _wire(agent)
    try:
        ffm.ForkWorkflow(client, _context(tmp), destination="tab").execute()
    except ffm.ForkError as exc:
        assert "no trusted session" in str(exc), exc
    else:
        raise AssertionError("expected ForkError")
    finally:
        ffm.agent_for = original
    assert not any(c[:2] == ["tab", "create"] for c in client.calls), client.calls


def test_unsupported_agent_is_named_in_the_error(tmp: Path) -> None:
    try:
        agent_for("codex")
    except AgentError as exc:
        message = str(exc)
        assert "codex" in message, message
        assert "Pi" in message and "OpenCode" in message, message
    else:
        raise AssertionError("expected AgentError")

    try:
        agent_for(None)
    except AgentError as exc:
        assert "no recognized agent" in str(exc), exc
    else:
        raise AssertionError("expected AgentError")

    assert agent_for("pi").name == "Pi"
    assert agent_for("opencode").name == "OpenCode"


def test_session_identity_shapes(tmp: Path) -> None:
    pi = agent_for("pi")
    assert pi.session_kind == "path"

    def pane(kind, value):
        return {"agent_session": {"agent": kind, "kind": "path" if kind == "pi" else "id",
                                  "source": f"herdr:{kind}", "value": value}}

    assert pi.session_from_pane(pane("pi", "/a/b.jsonl")) == "/a/b.jsonl"
    for bad in ("relative.jsonl", "/a/b.txt", "", None):
        try:
            pi.session_from_pane(pane("pi", bad))
        except AgentError:
            pass
        else:
            raise AssertionError(f"expected AgentError for pi session {bad!r}")

    oc = agent_for("opencode")
    assert oc.session_from_pane(pane("opencode", "ses_abc")) == "ses_abc"
    for bad in ("msg_abc", "ses_", "", None):
        try:
            oc.session_from_pane(pane("opencode", bad))
        except AgentError:
            pass
        else:
            raise AssertionError(f"expected AgentError for opencode session {bad!r}")


def test_cross_agent_session_metadata_is_rejected(tmp: Path) -> None:
    """A pi pane must not accept opencode-shaped metadata, and vice versa."""
    mismatched = {
        "agent_session": {"agent": "opencode", "kind": "id",
                          "source": "herdr:opencode", "value": "ses_x"}
    }
    try:
        agent_for("pi").session_from_pane(mismatched)
    except AgentError as exc:
        assert "trusted Pi session" in str(exc), exc
    else:
        raise AssertionError("expected AgentError")


def test_picker_lines_start_at_the_left_margin(tmp: Path) -> None:
    """Raw mode drops ONLCR, so a bare newline makes the list march rightward."""
    messages = [{"id": f"e{i}", "text": f"message number {i}"} for i in range(1, 6)]
    for selected in range(len(messages)):
        out = picker.render(messages, selected, 0, 4, "Fork Pi from Message")
        # Every line break must carry its own carriage return.
        assert "\n" not in out.replace("\r\n", ""), repr(out)
        # Replaying the cursor column proves each line returns to column 0 and
        # that options are indented identically apart from the selection marker.
        column = 0
        starts = []
        for ch in out:
            if ch == "\r":
                column = 0
            elif ch == "\n":
                starts.append(column)
                column = 0
            else:
                column += 1
        assert all(start == 0 for start in starts), (selected, starts)

    plain = picker._visible("x" * 500, 40)
    assert len(plain) == 40 and plain.endswith("…"), plain


def main() -> int:
    tests = [
        test_pi_backend,
        test_opencode_backend,
        test_source_pane_never_touched,
        test_picker_splits_from_source_pane,
        test_fork_label_skips_the_actual_dev_tab_event_hook,
        test_failed_fork_layout_closes_incomplete_tab,
        test_cancel_creates_no_destination,
        test_wrong_session_in_new_pane_is_rejected,
        test_backend_failure_closes_destination,
        test_unsupported_agent_is_named_in_the_error,
        test_session_identity_shapes,
        test_cross_agent_session_metadata_is_rejected,
        test_picker_lines_start_at_the_left_margin,
    ]
    for test in tests:
        with tempfile.TemporaryDirectory() as raw:
            test(Path(raw))
        print(f"ok  {test.__name__}")
    print(f"{len(tests)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
