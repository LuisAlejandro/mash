#!/usr/bin/env python3
"""Tests for scripts/translate.py against a fake translator.

The real script drives Pi, a paid model. These tests swap in a small local
command so `make test` never calls a model, and assert on what the script sent
and on the catalog bytes it wrote or refused to write.
"""

from __future__ import annotations

import json
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
REPO = TESTS.parents[1]
SCRIPT = REPO / "scripts" / "translate.py"
LANGUAGES = REPO / "packaging" / "i18n" / "languages.json"

sys.path.insert(0, str(TESTS))
import test_i18n_catalog as gate  # noqa: E402  (the shared stale/hash rules)

# Modes: echo translates, drop-placeholder loses a placeholder, garbage is not JSON.
FAKE = '''#!/usr/bin/env python3
import json, sys

mode, record = sys.argv[1], sys.argv[2]
prompt = sys.stdin.read()
open(record, "w", encoding="utf-8").write(prompt)
data = json.loads(prompt.split("Input:", 1)[1])
if mode == "echo":
    print(json.dumps({key: "fr " + text for key, text in data.items()}, ensure_ascii=False))
elif mode == "drop-placeholder":
    print(json.dumps({key: text.replace("{count}", "") for key, text in data.items()}, ensure_ascii=False))
else:
    print("sorry, this is not the JSON you asked for")
'''


def fixture(root: Path, english: dict[str, str]) -> Path:
    """An i18n root whose 14 languages already translate ``english``."""
    i18n = root / "i18n"
    component = i18n / "messages" / "helpers"
    component.mkdir(parents=True)
    shutil.copyfile(LANGUAGES, i18n / "languages.json")
    # The gate also requires every keybinding sheet in every language.
    for code in gate.EXPECTED_CODES:
        sheets = i18n / "quickref" / code
        sheets.mkdir(parents=True)
        for sheet in gate.QUICKREF_SHEETS:
            (sheets / sheet).write_text("sheet\n", encoding="utf-8")
    (component / "en.json").write_text(
        json.dumps(english, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    for code in gate.EXPECTED_CODES:
        if code == "en":
            continue
        translated = {
            key: {"text": f"{code}:{text}", "source_hash": gate.source_hash(text)}
            for key, text in english.items()
        }
        (component / f"{code}.json").write_text(
            json.dumps(translated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    return i18n


def drop_keys(i18n: Path, code: str, keys: tuple[str, ...]) -> None:
    path = i18n / "messages" / "helpers" / f"{code}.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    for key in keys:
        del data[key]
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class TranslateScriptTest(unittest.TestCase):
    def run_script(self, root: Path, i18n: Path, mode: str) -> tuple[subprocess.CompletedProcess, Path]:
        fake = root / "fake-translator.py"
        fake.write_text(FAKE, encoding="utf-8")
        record = root / "prompt.txt"
        command = " ".join(
            shlex.quote(part) for part in (sys.executable, str(fake), mode, str(record))
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--i18n-dir",
                str(i18n),
                "--translator",
                command,
            ],
            capture_output=True,
            text=True,
        )
        return result, record

    def catalog(self, i18n: Path, code: str) -> dict:
        path = i18n / "messages" / "helpers" / f"{code}.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_missing_keys_are_translated_with_hashes(self):
        english = {
            "helper.kept": "Kept",
            "helper.one": "Count {count} files",
            "helper.two": "Second",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            drop_keys(i18n, "fr", ("helper.one", "helper.two"))
            result, record = self.run_script(root, i18n, "echo")
            self.assertEqual(0, result.returncode, result.stderr)
            prompt = record.read_text(encoding="utf-8")
            catalog = self.catalog(i18n, "fr")
            english_after = self.catalog(i18n, "en")
            sources = {"packaging/helpers/example.sh": "".join(
                f"mash-t {key}\n" for key in english
            )}
            problems = gate.validate_i18n(i18n, sources)
        self.assertIn("helper.one", prompt)
        self.assertIn("helper.two", prompt)
        self.assertNotIn("helper.kept", prompt, "only the missing keys are sent")
        self.assertIn("Français", prompt, "the reply must name its target language")
        self.assertEqual({"text": "fr Count {count} files", "source_hash": gate.source_hash(english["helper.one"])}, catalog["helper.one"])
        self.assertEqual({"text": "fr Second", "source_hash": gate.source_hash(english["helper.two"])}, catalog["helper.two"])
        self.assertEqual("fr:Kept", catalog["helper.kept"]["text"], "existing entries are kept")
        self.assertEqual(english, {k: v for k, v in english_after.items()})
        self.assertEqual([], problems, "the written catalogs pass the completeness gate")

    def test_dropped_placeholder_is_rejected_and_files_are_unchanged(self):
        english = {"helper.one": "Count {count} files"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            drop_keys(i18n, "fr", ("helper.one",))
            before = self.snapshot(i18n)
            result, _ = self.run_script(root, i18n, "drop-placeholder")
            after = self.snapshot(i18n)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("placeholder", result.stderr)
        self.assertEqual(before, after)

    def test_complete_catalogs_make_no_translator_call(self):
        english = {"helper.one": "One"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            before = self.snapshot(i18n)
            result, record = self.run_script(root, i18n, "echo")
            after = self.snapshot(i18n)
            called = record.exists()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(called, "nothing to translate, no model call")
        self.assertEqual(before, after)
        self.assertIn("complete", result.stdout)

    def test_malformed_reply_leaves_every_file_unchanged(self):
        english = {"helper.one": "Count {count} files"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            drop_keys(i18n, "fr", ("helper.one",))
            before = self.snapshot(i18n)
            result, record = self.run_script(root, i18n, "garbage")
            after = self.snapshot(i18n)
            called = record.exists()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("translate:", result.stderr)
        self.assertTrue(called, "the translator really was called")
        self.assertEqual(before, after)

    def test_stale_and_placeholder_mismatched_entries_are_repaired(self):
        english = {"helper.one": "Count {count} files", "helper.two": "Two"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            path = i18n / "messages" / "helpers" / "fr.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["helper.one"]["text"] = "fichiers {n}"  # placeholder mismatch
            data["helper.two"] = {"text": "Deux", "source_hash": "000000000000"}  # stale
            path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            result, record = self.run_script(root, i18n, "echo")
            catalog = self.catalog(i18n, "fr")
            prompt = record.read_text(encoding="utf-8")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("helper.one", prompt)
        self.assertIn("helper.two", prompt)
        self.assertEqual("fr Count {count} files", catalog["helper.one"]["text"])
        self.assertEqual(gate.source_hash(english["helper.two"]), catalog["helper.two"]["source_hash"])

    def test_dry_run_lists_work_without_calling_the_translator(self):
        english = {"helper.one": "One"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            i18n = fixture(root, english)
            drop_keys(i18n, "fr", ("helper.one",))
            fake = root / "fake-translator.py"
            fake.write_text(FAKE, encoding="utf-8")
            record = root / "prompt.txt"
            command = " ".join(
                shlex.quote(part) for part in (sys.executable, str(fake), "echo", str(record))
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--i18n-dir",
                    str(i18n),
                    "--translator",
                    command,
                    "--dry-run",
                ],
                capture_output=True,
                text=True,
            )
            existed = record.exists()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("helpers/fr: 1 key(s) to translate", result.stdout)
        self.assertIn("helper.one", result.stdout)
        self.assertFalse(existed)

    def snapshot(self, i18n: Path) -> dict[str, str]:
        return {
            str(path.relative_to(i18n)): path.read_text(encoding="utf-8")
            for path in sorted((i18n / "messages").rglob("*.json"))
        }


if __name__ == "__main__":
    unittest.main()
