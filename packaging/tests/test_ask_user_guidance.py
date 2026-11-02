"""Exercise generated ask_user guidance without touching live Pi configuration."""

import json
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class AskUserGuidanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="mash-ask-user-guidance-")
        cls.addClassCleanup(temporary.cleanup)
        directory = pathlib.Path(temporary.name)
        rules = directory / "suite/src/rules"
        rules.mkdir(parents=True)
        (rules / "example.mdc").write_text(
            "---\nalwaysApply: true\ndescription: Existing rule\n---\nKeep existing rules.\n"
        )
        destination = directory / "APPEND_SYSTEM.md"
        subprocess.run(
            [
                "bash", "-c",
                'set -eu; source "$1"; mash_write_append_system "$2" "$3"',
                "bash", str(ROOT / "packaging/carry.sh"),
                str(directory / "suite"), str(destination),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        cls.guidance = destination.read_text()
        cls.recovery = cls.guidance.split("## Tool-call recovery\n", 1)[1].split("\n---\n", 1)[0]

    def test_copyable_examples_keep_single_and_batch_fields_separate(self):
        examples = [
            json.loads(example)
            for example in re.findall(r"```json\n(.*?)\n```", self.recovery, re.S)
        ]
        self.assertEqual(len(examples), 2, "provide one single and one batch example")
        single, batch = examples
        self.assertEqual(set(single), {"question", "context", "options"})
        self.assertEqual(set(batch), {"questions"})
        self.assertGreaterEqual(len(batch["questions"]), 2)
        self.assertLessEqual(len(batch["questions"]), 4)
        for question in [single, *batch["questions"]]:
            with self.subTest(question=question):
                self.assertEqual(set(question), {"question", "context", "options"})
                self.assertTrue(question["question"].strip())
                self.assertTrue(question["context"].strip())
                self.assertGreaterEqual(len(question["options"]), 2)
                for option in question["options"]:
                    self.assertTrue(option["title"].strip())
                    self.assertLessEqual(set(option), {"title", "description"})

    def test_recovery_is_bounded_and_preserves_explicit_approval(self):
        recovery = " ".join(self.recovery.split())
        for rule in (
            "model-only", "never through `codemode`", "Omit unused optional parameters",
            "Delete", "empty strings", "false", "Retry once", "plain chat",
            "wait for an explicit answer", "no approval",
        ):
            with self.subTest(rule=rule):
                self.assertIn(rule, recovery)
        for field in ("context", "options", "allowMultiple", "allowFreeform"):
            self.assertIn(f"`{field}`", self.recovery)
        self.assertIn("after the earlier answer", self.recovery)
        self.assertIn("batch heading", self.recovery)

    def test_existing_guidance_survives_generation(self):
        self.assertIn("uv_cwd", self.recovery)
        self.assertIn("Keep existing rules.", self.guidance)
        self.assertIn("## Review a finished session", self.guidance)


if __name__ == "__main__":
    unittest.main()
