#!/usr/bin/env python3
"""Completeness checks for Mash's language table and message catalogs.

Run with ``python3 packaging/tests/test_i18n_catalog.py`` for regression tests,
or ``--check`` to validate the checked-in catalogs from release preflight.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
REPO = PACKAGING.parent
I18N = PACKAGING / "i18n"
BUILD_COMMON = PACKAGING / "build-common.sh"

EXPECTED_CODES = (
    "bg", "cs", "de", "en", "es", "fr", "it", "ja", "ko", "pt-BR",
    "ru", "th", "uk", "vi", "zh-CN",
)
LANGUAGE_FIELDS = ("name", "locale", "fresh", "lazydocker", "lazygit", "ghostty", "voice")
PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
KEY_PATTERN = (
    r"(?:wizard|helper|pi|herdr)\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*"
    r"|plugin\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*"
)
KEY = re.compile(r"(?<![A-Za-z0-9_.-])(?:" + KEY_PATTERN + r")")
LOOKUP_PATTERNS = (
    re.compile(r"\bmash-t\s+['\"]?(" + KEY_PATTERN + r")(?![A-Za-z0-9_.-])"),
    re.compile(r"\b(?:t|translate|mash_t|mashT|i18n)\s*!?\s*\(\s*['\"](" + KEY_PATTERN + r")[\'\"]"),
)
SOURCE_SUFFIXES = {".mjs", ".js", ".py", ".rs", ".sh", ".bash", ".zsh", ".ts"}


def source_hash(text: str) -> str:
    """Short, stable digest tying a translation to its English source text."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def _read_json(path: Path, errors: list[str]):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        errors.append(f"missing {path}")
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"cannot read {path}: {exc}")
    return None


def validate_languages(path: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    rows = _read_json(path, errors)
    if not isinstance(rows, list):
        if rows is not None:
            errors.append("languages.json must contain a list of languages")
        return [], errors

    codes: list[str] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"languages.json entry {index + 1} must be an object")
            continue
        code = row.get("code")
        if not isinstance(code, str) or not code.strip():
            errors.append(f"languages.json entry {index + 1} is missing code")
        else:
            if code in codes:
                errors.append(f"languages.json has duplicate code {code!r}")
            codes.append(code)
        for field in LANGUAGE_FIELDS:
            value = row.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"languages.json entry {code or index + 1} is missing {field}")

    if len(rows) != len(EXPECTED_CODES):
        errors.append(f"languages.json must contain exactly 15 entries (found {len(rows)})")
    actual = set(codes)
    expected = set(EXPECTED_CODES)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        if missing:
            errors.append(f"languages.json is missing codes: {', '.join(missing)}")
        if extra:
            errors.append(f"languages.json has unsupported codes: {', '.join(extra)}")
    return codes, errors


def _is_shell_script(path: Path) -> bool:
    """Extensionless launchers such as packaging/mash are shell sources too."""
    if path.suffix:
        return False
    try:
        with path.open("rb") as handle:
            head = handle.read(200)
    except OSError:
        return False
    return head.startswith(b"#!") and b"sh" in head.split(b"\n", 1)[0]


def discover_sources(repo: Path) -> dict[str, str]:
    sources: dict[str, str] = {}
    for root_name in ("packaging", "scripts"):
        root = repo / root_name
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix not in SOURCE_SUFFIXES and not _is_shell_script(path):
                continue
            relative = path.relative_to(repo)
            if "tests" in relative.parts or "node_modules" in relative.parts or "target" in relative.parts:
                continue
            if path.name.startswith("test_") or ".test." in path.name:
                continue
            if relative.parts[:2] == ("packaging", "i18n"):
                continue
            try:
                sources[str(relative)] = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                continue
    return sources


def _load_catalogs(component_dir: Path, errors: list[str]) -> dict[str, dict]:
    catalogs: dict[str, dict] = {}
    for code in EXPECTED_CODES:
        path = component_dir / f"{code}.json"
        data = _read_json(path, errors)
        if data is None:
            continue
        if not isinstance(data, dict):
            errors.append(f"{path}: catalog must be a JSON object")
            continue
        catalogs[code] = data
    for path in sorted(component_dir.glob("*.json")):
        if path.stem not in EXPECTED_CODES:
            errors.append(f"unexpected message catalog {component_dir.name}/{path.name}")
    return catalogs


def _check_english(component: str, english: dict, errors: list[str]) -> None:
    for key, value in english.items():
        if not isinstance(key, str) or not KEY.fullmatch(key):
            errors.append(f"{component}/en.json has invalid message key {key!r}")
        if not isinstance(value, str):
            errors.append(f"{component}/en.json key {key!r} must have a string value")
        elif not value:
            errors.append(f"{component}/en.json key {key!r} has an empty value")


def _check_translations(component: str, english: dict, catalogs: dict[str, dict], errors: list[str]) -> None:
    for code in EXPECTED_CODES:
        if code == "en":
            continue
        translated = catalogs.get(code)
        if translated is None:
            continue
        for key in english:
            if key not in translated:
                errors.append(f"{component}/{code}: missing key {key!r}")
        for key, entry in translated.items():
            if key not in english:
                errors.append(f"{component}/{code}: translation-only key {key!r}")
                continue
            english_text = english[key]
            if not isinstance(english_text, str):
                continue
            if not isinstance(entry, dict):
                errors.append(f"{component}/{code}: {key!r} must contain text and source_hash")
                continue
            text = entry.get("text")
            recorded_hash = entry.get("source_hash")
            if not isinstance(text, str):
                errors.append(f"{component}/{code}: {key!r} has no string text")
                continue
            if not text:
                errors.append(f"{component}/{code}: {key!r} has an empty value")
            if recorded_hash != source_hash(english_text):
                errors.append(f"{component}/{code}: {key!r} is stale (source_hash mismatch)")
            if set(PLACEHOLDER.findall(text)) != set(PLACEHOLDER.findall(english_text)):
                errors.append(f"{component}/{code}: {key!r} has a placeholder mismatch")


QUICKREF_SHEETS = (
    "keybindings-quickref.txt",
    "keybindings-quickref.linux.txt",
    "keybindings-quickref.native.txt",
    "keybindings-quickref.native.linux.txt",
)


def _check_quickref(i18n_dir: Path) -> list[str]:
    """Every language ships each keybinding sheet mash-seed-sync may install."""
    errors: list[str] = []
    quickref = i18n_dir / "quickref"
    for code in EXPECTED_CODES:
        for sheet in QUICKREF_SHEETS:
            path = quickref / code / sheet
            if not path.is_file():
                errors.append(f"quickref/{code}/{sheet}: missing quick-reference sheet")
    return errors


def validate_i18n(i18n_dir: Path, source_files: dict[str, str] | None = None) -> list[str]:
    """Check every component catalog under messages/<component>/<lang>.json.

    Each component directory is owned by one unit of work, so a component must
    carry all fifteen languages, and a key may be defined by only one component.
    """
    errors: list[str] = []
    _, language_errors = validate_languages(i18n_dir / "languages.json")
    errors.extend(language_errors)

    messages_dir = i18n_dir / "messages"
    if not messages_dir.is_dir():
        errors.append(f"missing {messages_dir}")
        return errors
    for path in sorted(messages_dir.iterdir()):
        if path.is_file() and path.name != ".gitkeep":
            errors.append(f"unexpected file messages/{path.name}; catalogs live in messages/<component>/")

    combined: dict[str, str] = {}
    for component_dir in sorted(p for p in messages_dir.iterdir() if p.is_dir()):
        component = component_dir.name
        catalogs = _load_catalogs(component_dir, errors)
        for code in EXPECTED_CODES:
            if code not in catalogs and not (component_dir / f"{code}.json").exists():
                errors.append(f"{component}: missing {code}.json")
        english = catalogs.get("en")
        if english is None:
            continue
        _check_english(component, english, errors)
        for key, value in english.items():
            if key in combined:
                errors.append(f"{component}/en.json key {key!r} is also defined in another component")
            elif isinstance(value, str):
                combined[key] = value
        _check_translations(component, english, catalogs, errors)

    errors.extend(_check_quickref(i18n_dir))

    sources = discover_sources(REPO) if source_files is None else source_files
    used: dict[str, str] = {}
    for filename, source in sources.items():
        file_keys = {key for pattern in LOOKUP_PATTERNS for key in pattern.findall(source)}
        for key in sorted(file_keys):
            used.setdefault(key, filename)
            if key not in combined:
                errors.append(f"{filename}: undefined i18n key {key!r}")
    for key in combined:
        if key not in used:
            errors.append(f"unused catalog key {key!r}")

    return errors


def _fixture_catalogs(directory: Path, english: dict[str, str] | None = None, component: str = "helpers") -> Path:
    root = directory / "i18n"
    component_dir = root / "messages" / component
    component_dir.mkdir(parents=True)
    shutil.copyfile(I18N / "languages.json", root / "languages.json")
    english = english or {}
    (component_dir / "en.json").write_text(json.dumps(english), encoding="utf-8")
    for code in EXPECTED_CODES:
        if code == "en":
            continue
        translated = {
            key: {"text": value, "source_hash": source_hash(value)}
            for key, value in english.items()
        }
        (component_dir / f"{code}.json").write_text(json.dumps(translated), encoding="utf-8")
    return root


class I18nCatalogTest(unittest.TestCase):
    def problems(self, root: Path, sources: dict[str, str] | None = None) -> list[str]:
        return validate_i18n(root, sources)

    def test_missing_translation_names_key_and_language(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Count {count}"})
            path = root / "messages" / "helpers" / "th.json"
            path.write_text("{}", encoding="utf-8")
            problems = self.problems(root, {})
        self.assertTrue(any("helper.example" in problem and "th" in problem for problem in problems), problems)

    def test_changed_english_source_is_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Hello"})
            english = root / "messages" / "helpers" / "en.json"
            english.write_text(json.dumps({"helper.example": "Hello again"}), encoding="utf-8")
            problems = self.problems(root, {})
        self.assertTrue(any("helper.example" in problem and "de" in problem and "stale" in problem for problem in problems), problems)

    def test_placeholder_names_must_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Count {count}"})
            path = root / "messages" / "helpers" / "de.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["helper.example"]["text"] = "Anzahl {n}"
            path.write_text(json.dumps(data), encoding="utf-8")
            problems = self.problems(root, {})
        self.assertTrue(any("helper.example" in problem and "de" in problem and "placeholder" in problem for problem in problems), problems)

    def test_empty_and_translation_only_entries_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.empty": ""})
            path = root / "messages" / "helpers" / "de.json"
            data = json.loads(path.read_text(encoding="utf-8"))
            data["helper.extra"] = {"text": "Zusatz", "source_hash": source_hash("")}
            path.write_text(json.dumps(data), encoding="utf-8")
            problems = self.problems(root, {})
        self.assertTrue(any("helper.empty" in problem and "empty" in problem for problem in problems), problems)
        self.assertTrue(any("helper.extra" in problem and "translation-only" in problem for problem in problems), problems)

    def test_language_table_requires_fifteen_unique_named_languages(self):
        valid = json.loads((I18N / "languages.json").read_text(encoding="utf-8"))
        cases = []
        cases.append((valid[:-1], "exactly 15"))
        duplicate = json.loads(json.dumps(valid))
        duplicate[1]["code"] = duplicate[0]["code"]
        cases.append((duplicate, "duplicate code"))
        missing_name = json.loads(json.dumps(valid))
        del missing_name[0]["name"]
        cases.append((missing_name, "missing name"))
        for languages, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "languages.json"
                path.write_text(json.dumps(languages), encoding="utf-8")
                _, problems = validate_languages(path)
                self.assertTrue(any(expected in problem for problem in problems), problems)

    def test_source_lookups_must_be_defined_and_catalog_keys_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(
                Path(tmp),
                {"helper.defined": "Defined", "helper.orphan": "Unused"},
            )
            sources = {"packaging/helpers/example.py": 'mash-t helper.defined\nmash-t helper.missing\n'}
            problems = self.problems(root, sources)
        self.assertTrue(any("helper.missing" in problem and "undefined" in problem for problem in problems), problems)
        self.assertTrue(any("helper.orphan" in problem and "unused" in problem for problem in problems), problems)

    def test_staging_copies_language_table_and_all_catalogs(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            source = work / "source"
            packaging = source / "packaging"
            (packaging / "helpers").mkdir(parents=True)
            (packaging / "defaults").mkdir()
            shutil.copytree(I18N, packaging / "i18n")
            (packaging / "assets.json").write_text("{}\n", encoding="utf-8")
            (packaging / "assets.py").write_text("\n", encoding="utf-8")
            (source / "VERSION").write_text("1.0.0\n", encoding="utf-8")
            destination = work / "payload"
            command = (
                'set -e; source "$1"; root="$2"; '
                'mash_portable_scripts() { :; }; '
                'mash_stage_portable_payload "$3" linux-amd64'
            )
            result = subprocess.run(
                ["bash", "-c", command, "stage", str(BUILD_COMMON), str(source), str(destination)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertTrue((destination / "i18n" / "languages.json").is_file())
            for code in EXPECTED_CODES:
                with self.subTest(code=code):
                    self.assertTrue((destination / "i18n" / "messages" / "helpers" / f"{code}.json").is_file())

    def test_component_needs_all_fifteen_languages(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Hello"})
            (root / "messages" / "helpers" / "fr.json").unlink()
            problems = self.problems(root, {"packaging/helpers/x.sh": "mash-t helper.example\n"})
        self.assertTrue(any("helpers: missing fr.json" in problem for problem in problems), problems)

    def test_key_defined_by_two_components_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Hello"})
            other = root / "messages" / "pi"
            other.mkdir()
            for code in EXPECTED_CODES:
                (other / f"{code}.json").write_text(
                    json.dumps({"helper.example": {"text": "x", "source_hash": source_hash("Hello")}} if code != "en" else {"helper.example": "Hello"}),
                    encoding="utf-8",
                )
            problems = self.problems(root, {"packaging/helpers/x.sh": "mash-t helper.example\n"})
        self.assertTrue(any("also defined in another component" in problem for problem in problems), problems)

    def test_missing_quickref_sheet_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _fixture_catalogs(Path(tmp), {"helper.example": "Hello"})
            for code in EXPECTED_CODES:
                sheet_dir = root / "quickref" / code
                sheet_dir.mkdir(parents=True)
                for sheet in QUICKREF_SHEETS:
                    (sheet_dir / sheet).write_text("x\n", encoding="utf-8")
            (root / "quickref" / "th" / "keybindings-quickref.native.txt").unlink()
            problems = self.problems(root, {"packaging/helpers/x.sh": "mash-t helper.example\n"})
        self.assertTrue(any("quickref/th/keybindings-quickref.native.txt" in problem for problem in problems), problems)

    def test_repository_catalogs_are_complete(self):
        self.assertEqual([], validate_i18n(I18N), "\n".join(validate_i18n(I18N)))


def main(argv: list[str]) -> int:
    if argv == ["--check"]:
        problems = validate_i18n(I18N)
        if problems:
            for problem in problems:
                print(f"i18n: {problem}", file=sys.stderr)
            return 1
        print(f"i18n: {len(EXPECTED_CODES)} language catalogs complete")
        return 0
    if argv:
        print("usage: test_i18n_catalog.py [--check]", file=sys.stderr)
        return 2
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(I18nCatalogTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
