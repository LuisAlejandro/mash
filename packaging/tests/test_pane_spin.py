#!/usr/bin/env python3
"""mash-pane-spin animates from the side and stops the moment the program paints.

The stop rule is the subtle part and the reason this suite exists. Asking
"is my marker gone?" never fires: the program paints its own frame and the
marker line then sits on top of it instead of being erased. The rule is the
other way round -- stop as soon as anything on screen is not ours -- and a read
that fails must extend the animation rather than end it, or the user is left
looking at a frozen frame, which is the whole thing this replaces.
"""

import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
HELPER = ROOT / "packaging/helpers/mash-pane-spin"

spec = importlib.util.spec_from_loader(
    "pane_spin", importlib.machinery.SourceFileLoader("pane_spin", str(HELPER))
)
SPIN = importlib.util.module_from_spec(spec)
spec.loader.exec_module(SPIN)

LABEL = "Starting the agent…"


class FakeSession:
    def __init__(self, text=None, fail=False):
        self.text = text
        self.fail = fail

    def call(self, method, params, timeout=0.25):
        if self.fail:
            return None
        return {"type": "pane_read", "read": {"text": self.text}}


class SpinTest(unittest.TestCase):
    def test_our_own_frame_is_not_painted(self):
        session = FakeSession(f"  ⠋ {LABEL}\n")
        self.assertTrue(SPIN.screen_is_only_ours(session, "w:p1", LABEL))

    def test_blank_space_below_the_frame_is_not_painted(self):
        session = FakeSession(f"  ⠙ {LABEL}\n\n\n")
        self.assertTrue(SPIN.screen_is_only_ours(session, "w:p1", LABEL))

    def test_any_foreign_line_means_the_program_painted(self):
        session = FakeSession(f"  ⠹ {LABEL}\n  a line the agent drew\n")
        self.assertFalse(SPIN.screen_is_only_ours(session, "w:p1", LABEL))

    def test_a_failed_read_keeps_animating(self):
        # Stopping on an unreadable pane would show a frozen frame, which is
        # exactly what this replaces.
        self.assertTrue(SPIN.screen_is_only_ours(FakeSession(fail=True), "w:p1", LABEL))

    def test_the_payload_is_nested_under_read(self):
        # Herdr answers {"type": "pane_read", "read": {"text": ...}}. Reading
        # result["text"] yields nothing for ever, and the "still ours" default
        # then animates over the program's screen -- which is what happened.
        session = FakeSession(f"  {LABEL}\n  agent output\n")
        self.assertFalse(SPIN.screen_is_only_ours(session, "w:p1", LABEL))

    def test_a_missing_text_field_keeps_animating(self):
        class Weird:
            def call(self, method, params, timeout=0.25):
                return {"rows": []}

        self.assertTrue(SPIN.screen_is_only_ours(Weird(), "w:p1", LABEL))

    def test_frame_preserves_the_app_cursor_position(self):
        writes = []
        old_write = SPIN.os.write
        SPIN.os.write = lambda fd, data: writes.append(data) or len(data)
        try:
            SPIN.paint_frame(42, 0, LABEL)
        finally:
            SPIN.os.write = old_write
        self.assertEqual(len(writes), 1, "frame must be one terminal write")
        self.assertTrue(writes[0].startswith(b"\x1b7"), "save cursor before drawing")
        self.assertTrue(writes[0].endswith(b"\x1b8"), "restore cursor after drawing")
        self.assertIn(b"\x1b[1;1H", writes[0], "loader must not follow the input cursor")

    def test_no_terminal_write_after_the_app_has_painted(self):
        from unittest.mock import patch
        writes = []
        painted = [False]
        clock = [0.0]
        def read_screen(*args):
            painted[0] = True
            return False
        def write(fd, data):
            self.assertFalse(painted[0], "loader wrote after handover and moved the app cursor")
            writes.append(data)
            return len(data)
        def sleep(seconds):
            clock[0] += seconds
        with patch.dict(SPIN.os.environ, {"HERDR_SOCKET_PATH": "/unused"}), \
             patch.object(SPIN.os, "open", return_value=42), \
             patch.object(SPIN.os, "close"), \
             patch.object(SPIN.os, "write", side_effect=write), \
             patch.object(SPIN.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(SPIN.time, "sleep", side_effect=sleep), \
             patch.object(SPIN, "screen_is_only_ours", side_effect=read_screen):
            self.assertEqual(SPIN.main(["--pane", "w:p1", "--label", LABEL]), 0)
        self.assertTrue(painted[0])

    def test_arguments_are_required_and_parsed(self):
        self.assertIsNone(SPIN.parse([]))
        self.assertIsNone(SPIN.parse(["--pane", "w:p1"]))
        pane, label, max_ms = SPIN.parse(["--pane", "w:p1", "--label", LABEL])
        self.assertEqual((pane, label), ("w:p1", LABEL))
        self.assertEqual(max_ms, SPIN.DEFAULT_MAX_MS)

    def test_a_bad_budget_falls_back_rather_than_animating_forever(self):
        _, _, max_ms = SPIN.parse(["--pane", "w:p1", "--label", LABEL, "--max-ms", "soon"])
        self.assertEqual(max_ms, SPIN.DEFAULT_MAX_MS)


if __name__ == "__main__":
    unittest.main()
