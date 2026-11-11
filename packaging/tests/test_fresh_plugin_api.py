"""Mash's Fresh plugins may only call editor methods the pinned Fresh declares.

Fresh 0.5.2 removed `editor.removePath` from the plugin API. init.ts kept
calling it inside a try block, so the herdr-annotate handoff file was never
cleared and nothing reported why. types/fresh.d.ts is the declaration file of
the pinned Fresh, refreshed with every Fresh pin; a method missing from it is a
call that fails at runtime.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FRESH = ROOT / "packaging/defaults/fresh"
DECLARATIONS = FRESH / "types/fresh.d.ts"


def declared_methods():
    text = DECLARATIONS.read_text()
    return set(re.findall(r"^\s*([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", text, re.M))


def editor_calls():
    calls = {}
    for path in FRESH.rglob("*.ts"):
        if path.name.endswith(".d.ts"):
            continue
        for line_no, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith(("//", "*")):
                continue
            for name in re.findall(r"\beditor\s*\.\s*([A-Za-z_]\w*)\s*\(", line):
                calls.setdefault(name, f"{path.relative_to(ROOT)}:{line_no}")
    return calls


class FreshPluginApiTest(unittest.TestCase):
    def test_every_editor_call_is_declared_by_the_pinned_fresh(self):
        declared = declared_methods()
        calls = editor_calls()
        self.assertIn("replaceFile", declared, "the declaration file looks unparsed")
        self.assertTrue(calls, "no editor calls found; the scan is broken")
        missing = {name: where for name, where in calls.items() if name not in declared}
        self.assertEqual(missing, {}, "editor methods the pinned Fresh does not declare")


if __name__ == "__main__":
    unittest.main()
