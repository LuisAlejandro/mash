#!/usr/bin/env python3
"""mash-dev-tab-park stops idle dev-tab agents and wakes them on focus.

A Pi session plus its MCP children measured about 260 MB on this machine, and a
workspace left open holds one per tab. Parking is safe only if it is fussy about
when it may happen, which is what these cases pin down:

  * never a working agent, never one blocked on an approval
  * never a tab being looked at
  * never an agent with no session path, because it could not come back
  * the resume record is written before anything is stopped
  * a wake that fails keeps the record for the next attempt

The Herdr side and the kill are stubbed, so this runs anywhere.
"""

import importlib.machinery
import importlib.util
import json
import os
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
from pathlib import Path

ROOT = Path(__file__).parents[2]
HELPER = ROOT / "packaging/helpers/mash-dev-tab-park"

spec = importlib.util.spec_from_loader(
    "dev_tab_park", importlib.machinery.SourceFileLoader("dev_tab_park", str(HELPER))
)
PARK = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PARK)


class FakeHerdr:
    def __init__(self, agents=None, process=None, panes=None):
        self.agents = agents or []
        self.process = process or {}
        self.panes = panes or []
        self.calls = []

    def __call__(self, method, params=None, timeout=5.0):
        self.calls.append((method, dict(params or {})))
        if method == "workspace.list":
            return {"workspaces": [{"workspace_id": "visible", "focused": True, "active_tab_id": "visible:t1"}]}
        if method == "agent.list":
            return {"agents": self.agents}
        if method == "pane.get":
            return {"pane": {"pane_id": params["pane_id"], "tab_id": "t1"}}
        if method == "pane.list":
            return {"panes": self.panes}
        if method == "pane.process_info":
            return {"process_info": self.process.get(params.get("pane_id"), {"shell_pid": 404, "foreground_processes": [{"pid": 404, "argv0": "zsh"}]})}
        if method == "agent.start":
            started = agent(pane=params["pane_id"], name=params["name"], session=params["args"][1])
            started["interactive_ready"] = True
            self.agents.append(started)
            return {"agent": started}
        if method in ("pane.send_text", "pane.send_keys"):
            return {}
        raise AssertionError(f"unexpected call {method}")

    def started(self):
        return [c[1] for c in self.calls if c[0] == "agent.start"]

    def sent(self):
        return [c for c in self.calls if c[0] in ("pane.send_text", "pane.send_keys")]


def agent(status="idle", tab="t1", pane="w:p1", session="/s/x.jsonl", name="pi", kind="pi"):
    record = {
        "agent": kind,
        "agent_status": status,
        "tab_id": tab,
        "pane_id": pane,
        "name": name,
        "interactive_ready": True,
    }
    if session:
        record["agent_session"] = {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": session}
    return record


class ParkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._data = os.environ.get("MASH_DATA_DIR")
        os.environ["MASH_DATA_DIR"] = self.tmp.name
        self.addCleanup(self._restore, self._data)
        original_isfile = PARK.os.path.isfile
        PARK.os.path.isfile = lambda path: path == "/s/x.jsonl" or original_isfile(path)
        self.addCleanup(setattr, PARK.os.path, "isfile", original_isfile)
        self.now = 10_000.0

    def _restore(self, value):
        if value is None:
            os.environ.pop("MASH_DATA_DIR", None)
        else:
            os.environ["MASH_DATA_DIR"] = value

    def stale(self):
        return {"t1": self.now - PARK.PARK_AFTER - 1}

    def test_an_idle_agent_in_an_unseen_tab_may_be_parked(self):
        self.assertTrue(PARK.parkable(agent(), self.stale(), self.now))

    def test_a_working_agent_is_never_parked(self):
        self.assertFalse(PARK.parkable(agent(status="working"), self.stale(), self.now))

    def test_an_agent_waiting_on_a_person_is_never_parked(self):
        # blocked is an approval or question dialog: stopping it strands whoever
        # was about to answer.
        self.assertFalse(PARK.parkable(agent(status="blocked"), self.stale(), self.now))

    def test_a_tab_that_was_just_looked_at_is_left_alone(self):
        fresh = {"t1": self.now - 5}
        self.assertFalse(PARK.parkable(agent(), fresh, self.now))

    def test_an_agent_with_no_session_path_is_never_parked(self):
        # Nothing to resume with: it would be lost, not parked.
        self.assertFalse(PARK.parkable(agent(session=None), self.stale(), self.now))

    def test_only_pi_agents_are_considered(self):
        self.assertFalse(PARK.parkable(agent(kind="claude"), self.stale(), self.now))

    def test_the_record_is_written_before_the_agent_is_stopped(self):
        # A record without a kill is harmless; a kill without a record loses the
        # conversation.
        fake = FakeHerdr(agents=[agent()], process={"w:p1": {"foreground_processes": [{"argv0": "pi", "pid": 4242}]}})
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append((pid, sig))
        try:
            record = PARK.write_record(agent())
            self.assertTrue(record)
            self.assertTrue(PARK.park(agent()))
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [(4242, PARK.signal.SIGTERM)])
        saved = PARK.read_record("w:p1")
        self.assertEqual(saved["session"], "/s/x.jsonl")
        self.assertEqual(saved["tab"], "t1")

    def test_the_pi_process_is_found_by_argv0_not_by_name(self):
        # Pi runs as `node`, so matching on the process name would pick a
        # language server or an MCP child instead.
        fake = FakeHerdr(
            process={
                "w:p1": {
                    "foreground_processes": [
                        {"name": "node", "argv0": "typescript-language-server", "pid": 111},
                        {"name": "node", "argv0": "pi", "pid": 4242},
                    ]
                }
            }
        )
        original = PARK.call
        PARK.call = fake
        try:
            self.assertEqual(PARK.pi_pid("w:p1"), 4242)
        finally:
            PARK.call = original

    def test_a_park_that_cannot_find_the_process_keeps_the_record(self):
        fake = FakeHerdr(agents=[agent()], process={"w:p1": {"foreground_processes": []}})
        original = PARK.call
        PARK.call = fake
        try:
            self.assertFalse(PARK.park(agent()))
        finally:
            PARK.call = original
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_waking_resumes_the_recorded_session(self):
        PARK.write_record(agent())
        fake = FakeHerdr()
        original = PARK.call
        PARK.call = fake
        try:
            self.assertTrue(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(
            fake.started(),
            [{"name": "pi", "kind": "pi", "pane_id": "w:p1", "args": ["--session", "/s/x.jsonl"], "timeout_ms": 60000}],
        )
        self.assertIsNone(PARK.read_record("w:p1"))

    def test_a_failed_wake_keeps_the_record_for_the_next_focus(self):
        PARK.write_record(agent())
        fake = FakeHerdr()

        def boom(method, params=None, timeout=5.0):
            raise PARK.Unavailable("session busy")

        original = PARK.call
        PARK.call = boom
        try:
            self.assertFalse(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_a_tick_parks_only_what_is_parkable(self):
        # Three tabs, one agent each: stale and idle (parkable), stale and
        # working (pinned), and freshly seen (not yet). Only the first goes.
        fake = FakeHerdr(
            agents=[
                agent(pane="w:p1", tab="t1"),
                agent(pane="w:p2", tab="t2", status="working"),
                agent(pane="w:p3", tab="t3"),
            ],
            process={
                "w:p1": {"foreground_processes": [{"argv0": "pi", "pid": 11}]},
                "w:p2": {"foreground_processes": [{"argv0": "pi", "pid": 22}]},
                "w:p3": {"foreground_processes": [{"argv0": "pi", "pid": 33}]},
            },
        )
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append(pid)
        try:
            last_focus = {
                "t1": self.now - PARK.PARK_AFTER - 1,
                "t2": self.now - PARK.PARK_AFTER - 1,
                "t3": self.now - 5,
            }
            self.assertEqual(PARK.tick(last_focus, self.now), 1)
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [11])

    # --- the editor half of a dev tab -------------------------------------

    def test_only_a_daemon_backed_editor_is_ever_parked(self):
        # A tagged pane's buffers live in the directory's daemon, so detaching it
        # loses nothing. An untagged Fresh (telescope, sesh, a bare `fresh`) owns
        # its editor outright and keeps it.
        fake = FakeHerdr(
            panes=[
                {"pane_id": "w:p1", "tab_id": "t1", "cwd": "/w", "tokens": {"mash-fresh-daemon": "1"}},
                {"pane_id": "w:p2", "tab_id": "t1", "cwd": "/w", "tokens": {}},
            ]
        )
        original = PARK.call
        PARK.call = fake
        try:
            self.assertEqual([p["pane_id"] for p in PARK.editor_panes()], ["w:p1"])
        finally:
            PARK.call = original

    def test_parking_the_editor_detaches_it_and_records_how_to_return(self):
        fake = FakeHerdr(process={"w:p1": {"foreground_processes": [{"argv0": "fresh", "name": "fresh", "pid": 99}]}})
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append(pid)
        try:
            self.assertTrue(PARK.park_editor({"pane_id": "w:p1", "tab_id": "t1", "cwd": "/w"}))
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [99])
        self.assertEqual(PARK.read_record("w:p1")["kind"], "editor")

    def test_an_editor_pane_already_a_shell_is_left_alone(self):
        # Nothing to stop, and a record would make the wake start an editor in a
        # pane somebody is using for something else.
        fake = FakeHerdr(process={"w:p1": {"foreground_processes": []}})
        original = PARK.call
        PARK.call = fake
        try:
            self.assertFalse(PARK.park_editor({"pane_id": "w:p1", "tab_id": "t1", "cwd": "/w"}))
        finally:
            PARK.call = original
        self.assertIsNone(PARK.read_record("w:p1"))

    def test_waking_an_editor_re_attaches_to_the_daemon(self):
        fake = FakeHerdr()
        original = PARK.call
        PARK.call = fake
        try:
            PARK.save_record("w:p1", {"kind": "editor", "tab": "t1", "cwd": "/w"})
            self.assertTrue(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(
            fake.sent(),
            [
                ("pane.send_text", {"pane_id": "w:p1", "text": "herdr-fresh-pane --daemon ."}),
                ("pane.send_keys", {"pane_id": "w:p1", "keys": ["Enter"]}),
            ],
        )
        self.assertIsNone(PARK.read_record("w:p1"))

    def test_a_tab_with_a_working_agent_keeps_its_editor_open(self):
        # Taking the editor away from a tab whose agent is mid-turn or waiting on
        # a person costs them their context; the few tens of megabytes stay.
        fake = FakeHerdr(
            agents=[agent(pane="w:p9", tab="t1", status="working")],
            panes=[{"pane_id": "w:p1", "tab_id": "t1", "cwd": "/w", "tokens": {"mash-fresh-daemon": "1"}}],
            process={"w:p1": {"foreground_processes": [{"argv0": "fresh", "name": "fresh", "pid": 99}]}},
        )
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append(pid)
        try:
            PARK.tick({"t1": self.now - PARK.PARK_AFTER - 1}, self.now)
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [])
        self.assertIsNone(PARK.read_record("w:p1"))

    def test_one_tick_does_not_stop_everything_at_once(self):
        # Several idle tabs can expire together. Keep session flushes bounded.
        agents = [agent(pane=f"w:p{i}", tab=f"t{i}") for i in range(10)]
        fake = FakeHerdr(
            agents=agents,
            process={f"w:p{i}": {"foreground_processes": [{"argv0": "pi", "pid": 100 + i}]} for i in range(10)},
        )
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append(pid)
        try:
            stalled = {f"t{i}": self.now - PARK.PARK_AFTER - 1 for i in range(10)}
            parked = PARK.tick(stalled, self.now)
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(parked, PARK.PARK_BURST)
        self.assertEqual(len(killed), PARK.PARK_BURST)

    def test_a_stale_tab_parks_its_agent_and_its_editor(self):
        fake = FakeHerdr(
            agents=[agent(pane="w:p9", tab="t1")],
            panes=[{"pane_id": "w:p1", "tab_id": "t1", "cwd": "/w", "tokens": {"mash-fresh-daemon": "1"}}],
            process={
                "w:p9": {"foreground_processes": [{"argv0": "pi", "pid": 11}]},
                "w:p1": {"foreground_processes": [{"argv0": "fresh", "name": "fresh", "pid": 22}]},
            },
        )
        killed = []
        original_call, original_kill = PARK.call, PARK.os.kill
        PARK.call, PARK.os.kill = fake, lambda pid, sig: killed.append(pid)
        try:
            parked = PARK.tick({"t1": self.now - PARK.PARK_AFTER - 1}, self.now)
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(parked, 2)
        self.assertEqual(sorted(killed), [11, 22])

    def test_currently_visible_tab_never_parks_after_ten_minutes(self):
        fake = FakeHerdr(agents=[agent()])
        original_call, original_park = PARK.call, PARK.park
        stopped = []
        def call(method, params=None, timeout=5.0):
            if method == "workspace.list":
                return {"workspaces": [{"workspace_id": "w1", "focused": True, "active_tab_id": "t1"}]}
            return fake(method, params, timeout)
        PARK.call, PARK.park = call, lambda a: stopped.append(a) or True
        try:
            PARK.tick(self.stale(), self.now)
        finally:
            PARK.call, PARK.park = original_call, original_park
        self.assertEqual(stopped, [], "a visible tab must remain protected indefinitely")

    def test_visible_tab_protects_both_editor_and_agent_for_hours(self):
        fake = FakeHerdr(
            agents=[agent(tab="visible:t1")],
            panes=[{"pane_id": "w:editor", "tab_id": "visible:t1", "tokens": {"mash-fresh-daemon": "1"}}],
        )
        original_call, original_park, original_editor = PARK.call, PARK.park, PARK.park_editor
        stopped = []
        PARK.call = fake
        PARK.park = lambda a: stopped.append("agent") or True
        PARK.park_editor = lambda p: stopped.append("editor") or True
        try:
            clock = {"visible:t1": 0}
            for now in (self.now, self.now + 7200):
                PARK.tick(clock, now)
                self.assertEqual(clock["visible:t1"], now)
            self.assertEqual(stopped, [])
        finally:
            PARK.call, PARK.park, PARK.park_editor = original_call, original_park, original_editor

    def test_editor_rechecks_busy_sibling_before_stopping(self):
        fake = FakeHerdr(agents=[agent(status="working")])
        original_call, original_kill = PARK.call, PARK.os.kill
        killed = []
        PARK.call, PARK.os.kill = fake, lambda *args: killed.append(args)
        try:
            self.assertFalse(PARK.park_editor({"pane_id": "w:editor", "tab_id": "t1"}))
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [])

    def test_unknown_visibility_fails_closed(self):
        fake = FakeHerdr(agents=[agent()])
        original_call, original_park = PARK.call, PARK.park
        stopped = []
        def call(method, params=None, timeout=5.0):
            if method == "workspace.list":
                raise PARK.Unavailable("temporarily disconnected")
            return fake(method, params, timeout)
        PARK.call, PARK.park = call, lambda a: stopped.append(a) or True
        try:
            PARK.tick(self.stale(), self.now)
        finally:
            PARK.call, PARK.park = original_call, original_park
        self.assertEqual(stopped, [])

    def test_an_unobserved_new_tab_gets_a_full_grace_period(self):
        self.assertFalse(PARK.parkable(agent(tab="new"), {}, self.now))

    def test_unnamed_agents_do_not_compete_for_the_name_pi(self):
        PARK.write_record(agent(pane="w:p1", name=None))
        PARK.write_record(agent(pane="w:p2", name=None))
        fake = FakeHerdr()
        original = PARK.call
        PARK.call = fake
        try:
            self.assertTrue(PARK.wake("w:p1"))
            self.assertTrue(PARK.wake("w:p2"))
        finally:
            PARK.call = original
        names = [a["name"] for a in fake.started()]
        self.assertEqual(len(set(names)), 2)
        self.assertNotIn("pi", names)

    def test_a_saved_name_owned_by_another_agent_uses_a_unique_fallback(self):
        PARK.write_record(agent(name="pi"))
        fake = FakeHerdr(agents=[agent(pane="other:p9", name="pi")])
        original = PARK.call
        PARK.call = fake
        try:
            self.assertTrue(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertNotEqual(fake.started()[0]["name"], "pi")

    def test_wake_never_types_into_an_occupied_pane(self):
        PARK.save_record("w:p1", {"kind": "editor", "tab": "t1"})
        fake = FakeHerdr(process={"w:p1": {"shell_pid": 404,
                          "foreground_processes": [{"pid": 405, "argv0": "vim"}]}})
        original = PARK.call
        PARK.call = fake
        try:
            self.assertFalse(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(fake.sent(), [])
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_reused_or_moved_pane_is_not_resumed(self):
        PARK.write_record(agent(tab="old-tab"))
        fake = FakeHerdr()
        original = PARK.call
        PARK.call = fake
        try:
            self.assertFalse(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(fake.started(), [])
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_missing_session_file_preserves_recovery_record(self):
        PARK.write_record(agent(session="/no-such-session-891035.jsonl"))
        fake = FakeHerdr()
        original = PARK.call
        PARK.call = fake
        try:
            self.assertFalse(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(fake.started(), [])
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_already_running_recorded_session_is_not_launched_twice(self):
        PARK.write_record(agent())
        fake = FakeHerdr(agents=[agent()])
        original = PARK.call
        PARK.call = fake
        try:
            self.assertTrue(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertEqual(fake.started(), [])
        self.assertIsNone(PARK.read_record("w:p1"))

    def test_wake_without_readiness_keeps_record(self):
        PARK.write_record(agent())
        fake = FakeHerdr()
        original = PARK.call
        def call(method, params=None, timeout=5.0):
            if method == "agent.start":
                return {"agent": {"interactive_ready": False}}
            return fake(method, params, timeout)
        PARK.call = call
        try:
            self.assertFalse(PARK.wake("w:p1"))
        finally:
            PARK.call = original
        self.assertIsNotNone(PARK.read_record("w:p1"))

    def test_visible_failed_wakes_are_retried_by_maintenance(self):
        PARK.write_record(agent(tab="visible:t1"))
        fake = FakeHerdr()
        original_call, original_wake = PARK.call, PARK.wake
        attempts = []
        PARK.call = fake
        PARK.wake = lambda pane: attempts.append(pane) or False
        try:
            PARK.tick({}, self.now, wake_only=True)
            PARK.tick({}, self.now + 30, wake_only=True)
        finally:
            PARK.call, PARK.wake = original_call, original_wake
        self.assertEqual(attempts, ["w:p1", "w:p1"])

    def test_wake_only_mode_never_stops_a_process(self):
        fake = FakeHerdr(agents=[agent()])
        original_call, original_kill = PARK.call, PARK.os.kill
        killed = []
        PARK.call, PARK.os.kill = fake, lambda *args: killed.append(args)
        try:
            self.assertEqual(PARK.tick(self.stale(), self.now, wake_only=True), 0)
        finally:
            PARK.call, PARK.os.kill = original_call, original_kill
        self.assertEqual(killed, [])

    def test_unpersisted_session_is_not_parked(self):
        self.assertFalse(PARK.parkable(agent(session="/future/session.jsonl"), self.stale(), self.now))

    def test_singleton_lock_survives_until_follow_returns(self):
        import fcntl
        old_path, old_seed = PARK.socket_path, PARK.seed_launch_staleness
        old_follow, old_visible, old_wake = PARK.follow, PARK.visible_tabs, PARK.wake_visible
        path = Path(self.tmp.name) / "socket-placeholder"
        path.touch()
        results = []
        def follow(*args, **kwargs):
            with open(Path(self.tmp.name) / "run/dev-tab-park.lock", "a") as second:
                try:
                    fcntl.flock(second, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    results.append("held")
                else:
                    results.append("released too early")
            raise KeyboardInterrupt
        PARK.socket_path = lambda: str(path)
        PARK.seed_launch_staleness = lambda *args: None
        PARK.visible_tabs = lambda: {"t1"}
        PARK.wake_visible = lambda *args: None
        PARK.follow = follow
        try:
            self.assertEqual(PARK.main(), 0)
        finally:
            PARK.socket_path, PARK.seed_launch_staleness = old_path, old_seed
            PARK.follow, PARK.visible_tabs, PARK.wake_visible = old_follow, old_visible, old_wake
        self.assertEqual(results, ["held"])

    def test_focus_switch_starts_previous_tabs_clock_at_blur(self):
        for event in ("tab_focused", "workspace_focused"):
            with self.subTest(event=event):
                sock = Mock()
                sock.recv.side_effect = [(json.dumps({"event": event}) + "\n").encode(), KeyboardInterrupt]
                clock = {"old": 0}
                with patch.object(PARK.socket, "socket", return_value=sock), \
                     patch.object(PARK, "visible_tabs", side_effect=[{"old"}, {"new"}]), \
                     patch.object(PARK.time, "monotonic", return_value=self.now), \
                     patch.object(PARK, "wake_visible") as wake:
                    with self.assertRaises(KeyboardInterrupt):
                        PARK.follow("unused", clock)
                self.assertEqual(clock["old"], self.now)
                wake.assert_called_once_with({"new"}, clock, self.now)

    def test_timeout_is_one_hour_for_both_panes(self):
        self.assertEqual(PARK.PARK_AFTER, 3600.0)

    def test_busy_time_does_not_count_toward_either_panes_idle_period(self):
        fake = FakeHerdr(
            agents=[agent(status="working")],
            panes=[{"pane_id": "w:editor", "tab_id": "t1", "tokens": {"mash-fresh-daemon": "1"}}],
        )
        original_call, original_park, original_editor = PARK.call, PARK.park, PARK.park_editor
        stopped = []
        PARK.call = fake
        PARK.park = lambda a: stopped.append("agent") or True
        PARK.park_editor = lambda p: stopped.append("editor") or True
        try:
            clock = self.stale()
            PARK.tick(clock, self.now)
            fake.agents[0]["agent_status"] = "idle"
            idle_start = self.now + PARK.TICK
            PARK.tick(clock, idle_start)
            PARK.tick(clock, idle_start + PARK.PARK_AFTER - 1)
            self.assertEqual(stopped, [])
            PARK.tick(clock, idle_start + PARK.PARK_AFTER)
            self.assertEqual(stopped, ["agent", "editor"])
        finally:
            PARK.call, PARK.park, PARK.park_editor = original_call, original_park, original_editor

    def test_a_launch_gives_every_tab_a_full_idle_period(self):
        fake = FakeHerdr(
            agents=[],
        )

        def call(method, params=None, timeout=5.0):
            if method == "workspace.list":
                return {"workspaces": [{"workspace_id": "w1"}]}
            if method == "tab.list":
                return {
                    "tabs": [
                        {"tab_id": "t1", "focused": True},
                        {"tab_id": "t2"},
                    ]
                }
            raise AssertionError(method)

        original = PARK.call
        PARK.call = call
        try:
            last_focus = {}
            PARK.seed_launch_staleness(last_focus, self.now)
        finally:
            PARK.call = original
        self.assertEqual(last_focus["t1"], self.now, "focus must receive a full grace period")
        self.assertEqual(last_focus["t2"], self.now, "hidden tabs must receive a full grace period too")


if __name__ == "__main__":
    unittest.main()
