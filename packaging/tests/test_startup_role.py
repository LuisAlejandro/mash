#!/usr/bin/env python3
"""Quiet shells reserve automatic panes before any prompt/command can paint."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader("startup_role", str(ROOT / "packaging/helpers/mash-startup-role"))
spec = importlib.util.spec_from_loader(loader.name, loader)
ROLE = importlib.util.module_from_spec(spec)
loader.exec_module(ROLE)


class StartupRoleTest(unittest.TestCase):
    def check(self, pane, tab):
        def call(method, params):
            return {"pane": pane} if method == "pane.get" else {"tab": tab}
        with patch.dict(os.environ, {"HERDR_PANE_ID": "w1:p1", "MASH_PANE_STARTUP": ""}):
            return ROLE.role(call)

    def test_restored_pi_has_no_shell_prompt(self):
        self.assertEqual(self.check({"agent": "pi"}, {}), "agent")

    def test_restored_fresh_has_no_shell_prompt(self):
        self.assertEqual(self.check({"agent": "fresh"}, {}), "editor")

    def test_native_plus_tab_reserves_editor_before_hook_types(self):
        # Numbered 2+ and still single-pane: exactly the tab the + hook enriches.
        self.assertEqual(self.check({"tab_id": "w1:t2"}, {"number": 2, "label": "2", "pane_count": 1}), "editor")

    def test_number_is_used_because_the_label_arrives_later(self):
        self.assertEqual(self.check({"tab_id": "w1:t2"}, {"number": 3, "label": "", "pane_count": 1}), "editor")

    def test_initial_shell_workspace_is_not_captured(self):
        self.assertEqual(self.check({"tab_id": "w1:t1"}, {"number": 1, "label": "1", "pane_count": 1}), "")

    def test_explicit_shell_and_plugin_tabs_are_not_captured(self):
        # Exactly the labels our launchers pass; the gate mirrors the hook, so
        # any other numbered single-pane tab is treated as a "+" press.
        for name in ("herdr-tab-launcher-plain", "herdr-tab-launcher-probe",
                     "herdr-tab-launcher-dev", "herdr-tab-launcher-quiet-probe"):
            self.assertEqual(self.check({"tab_id": "w1:t2"}, {"number": 4, "label": name, "pane_count": 1}), "")

    def test_explicit_role_does_not_need_an_api_call(self):
        with patch.dict(os.environ, {"MASH_PANE_STARTUP": "agent"}):
            self.assertEqual(ROLE.role(lambda *args: self.fail("unnecessary API call")), "agent")

    def test_restored_parked_pane_keeps_commands_hidden(self):
        import tempfile, json
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"MASH_DATA_DIR": tmp}):
            path = Path(tmp) / "local/state/dev-tab-park/w1_p1"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"pane": "w1:p1", "tab": "w1:t1", "kind": "agent"}))
            self.assertEqual(self.check({"tab_id": "w1:t1"}, {}), "agent")
            self.assertEqual(self.check({"tab_id": "another-tab"}, {}), "")

    def test_disconnection_does_not_capture_a_user_shell(self):
        def failed(*args):
            raise OSError("not connected")
        with patch.dict(os.environ, {"HERDR_PANE_ID": "w1:p1", "MASH_PANE_STARTUP": ""}):
            self.assertEqual(ROLE.role(failed), "")


if __name__ == "__main__":
    unittest.main()
