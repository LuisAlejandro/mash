#!/usr/bin/env python3
"""mash-fresh-split-sync keeps a workspace's dev tabs at one split ratio.

A Fresh daemon draws a single grid for every terminal attached to it, sized by
the first client. Two dev tabs at different ratios therefore cannot both be
right, and the wrong one either wraps its lines until the menu bar scrolls away
or letterboxes a small editor. The syncer's job is to make "the editor size" a
property of the workspace.

The Herdr side is stubbed here, so these run anywhere and assert only the
decisions the helper makes: which tabs take part, which ratio wins, and that it
does not answer its own writes.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
HELPER = ROOT / "packaging/helpers/mash-fresh-split-sync"

spec = importlib.util.spec_from_loader(
    "split_sync", importlib.machinery.SourceFileLoader("split_sync", str(HELPER))
)
SYNC = importlib.util.module_from_spec(spec)
spec.loader.exec_module(SYNC)


class FakeHerdr:
    """Records calls and answers from a fixture."""

    def __init__(self, panes, layouts, workspaces=None):
        self.panes = panes
        self.layouts = layouts
        self.workspaces = workspaces or []
        self.calls = []
        self.ratios = {}

    def __call__(self, method, params=None, timeout=5.0):
        self.calls.append((method, dict(params or {})))
        if method == "pane.list":
            return {"panes": self.panes}
        if method == "workspace.list":
            return {"workspaces": self.workspaces}
        if method == "layout.export":
            layout = self.layouts.get(params["tab_id"])
            if layout is None:
                raise SYNC.Unavailable("no such tab")
            return {"layout": dict(layout, tab_id=params["tab_id"])}
        if method == "layout.set_split_ratio":
            self.ratios[params["tab_id"]] = params["ratio"]
            # Apply it for real, the way Herdr does: a later export of this tab
            # must report the new ratio, or the echo of our own write would look
            # like a user drag.
            layout = self.layouts.get(params["tab_id"])
            if layout:
                layout["root"]["ratio"] = params["ratio"]
            return {}
        if method == "pane.zoom":
            return {}
        raise AssertionError(f"unexpected call {method}")

    def ratio_writes(self):
        return [c for c in self.calls if c[0] == "layout.set_split_ratio"]


def pane(pane_id, tab_id, daemon=True, focused=False):
    tokens = {"mash-fresh-daemon": "1"} if daemon else {}
    return {"pane_id": pane_id, "tab_id": tab_id, "tokens": tokens, "focused": focused}


def dev_layout(ratio, panes=2, zoomed=False):
    if panes == 2:
        root = {
            "type": "split",
            "direction": "right",
            "ratio": ratio,
            "first": {"type": "pane", "pane_id": "w:p1"},
            "second": {"type": "pane", "pane_id": "w:p2"},
        }
    else:
        # Split again inside the right half: no single ratio describes the
        # Fresh pane's edge any more.
        root = {
            "type": "split",
            "direction": "right",
            "ratio": ratio,
            "first": {"type": "pane", "pane_id": "w:p1"},
            "second": {
                "type": "split",
                "direction": "down",
                "ratio": 0.5,
                "first": {"type": "pane", "pane_id": "w:p2"},
                "second": {"type": "pane", "pane_id": "w:p3"},
            },
        }
    return {"root": root, "zoomed": zoomed, "focused_pane_id": "w:p1"}


class SyncTest(unittest.TestCase):
    def run_sync(self, fake, workspace="w1", source=None):
        original = SYNC.call
        SYNC.call = fake
        try:
            applied = {}
            SYNC.sync_workspace(workspace, applied, source=source)
            return applied
        finally:
            SYNC.call = original

    def test_the_tab_that_moved_keeps_its_size_and_the_others_follow(self):
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2")],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.45)},
        )
        self.run_sync(fake, source="t2")
        self.assertEqual(fake.ratios, {"t1": 0.45})

    def test_the_first_client_is_never_the_only_one_that_moves(self):
        # The property that matters: whichever tab the user dragged, the other
        # one is the one written to, so both end up equal.
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2")],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.7)},
        )
        self.run_sync(fake, source="t1")
        self.assertEqual(fake.ratios, {"t2": 0.6})

    def test_private_editors_are_left_alone(self):
        # A telescope or sesh pane has its own editor and its own size.
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2"), pane("w:p9", "t9", daemon=False)],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.5), "t9": dev_layout(0.9)},
        )
        self.run_sync(fake, source="t2")
        self.assertNotIn("t9", fake.ratios)
        self.assertEqual(fake.ratios, {"t1": 0.5})

    def test_a_tab_split_again_is_not_a_dev_tab(self):
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2")],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.5, panes=3)},
        )
        self.run_sync(fake, source="t2")
        self.assertEqual(fake.ratios, {})

    def test_one_dev_tab_has_nothing_to_match(self):
        fake = FakeHerdr([pane("w:p1", "t1")], {"t1": dev_layout(0.6)})
        self.run_sync(fake, source="t1")
        self.assertEqual(fake.ratios, {})

    def test_its_own_write_is_not_answered_again(self):
        # set_split_ratio makes Herdr emit layout.updated for every tab it
        # touched. Without remembering what was written, the two tabs would keep
        # replying to each other.
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2")],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.45)},
        )
        original = SYNC.call
        SYNC.call = fake
        try:
            applied = {}
            SYNC.sync_workspace("w1", applied, source="t2")
            writes = len(fake.ratio_writes())
            # The echo of our own write, arriving as an event for t1.
            SYNC.sync_workspace("w1", applied, source="t1")
            self.assertEqual(len(fake.ratio_writes()), writes)
        finally:
            SYNC.call = original

    def test_a_zoomed_dev_tab_is_unzoomed_instead_of_resized(self):
        # Zoom hides the other pane without changing the ratio, so the ratio no
        # longer describes the size on screen.
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2")],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.6, zoomed=True)},
        )
        original = SYNC.call
        SYNC.call = fake
        try:
            layout = fake.layouts["t2"]
            self.assertTrue(layout["zoomed"])
            SYNC.unzoom("w:p1")
        finally:
            SYNC.call = original
        self.assertEqual([c[0] for c in fake.calls], ["pane.zoom"])
        self.assertEqual(fake.calls[0][1]["mode"], "off")

    def test_startup_converges_on_the_focused_tab(self):
        # Nothing guarantees they start equal: the tabs were dragged while the
        # syncer was not running.
        fake = FakeHerdr(
            [pane("w:p1", "t1"), pane("w:p2", "t2", focused=True)],
            {"t1": dev_layout(0.6), "t2": dev_layout(0.52)},
            workspaces=[{"workspace_id": "w1"}],
        )
        original = SYNC.call
        SYNC.call = fake
        try:
            SYNC.startup_pass({})
        finally:
            SYNC.call = original
        self.assertEqual(fake.ratios, {"t1": 0.52})


if __name__ == "__main__":
    unittest.main()
