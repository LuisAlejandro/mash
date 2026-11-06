#!/usr/bin/env python3
"""Fill or refresh Mash's translation catalogs by driving Pi.

Run this before a release, then gate the result with ``scripts/preflight.sh``:

    python3 scripts/translate.py

For every component under ``packaging/i18n/messages`` and every language but
English it collects the keys that are missing, stale (their English source
changed after they were translated) or placeholder-mismatched, asks the
translator for them in batches, checks each reply and writes the new entries
with their source hashes. ``en.json`` is the source of truth and is never
written.

The missing/stale rules are imported from the completeness gate,
``packaging/tests/test_i18n_catalog.py``, so this script repairs exactly what
preflight would otherwise reject. Nothing is written until every reply has
validated: a failed run leaves the catalogs byte-identical.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import shlex
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
I18N = REPO / "packaging" / "i18n"
GATE = REPO / "packaging" / "tests" / "test_i18n_catalog.py"

# Pi's print mode: the prompt arrives on stdin, the reply on stdout.
DEFAULT_TRANSLATOR = "pi --print --no-session --no-tools"
DEFAULT_BATCH_SIZE = 40

PROMPT = """\
You translate the user interface of Mash, a terminal application.

Target language: {name} ({code}).
Translate every value of the JSON object below into {name}. Reply with one JSON
object that has exactly the same keys and nothing else: no explanation, no
markdown fence.

Rules:
- Keep every {{placeholder}} exactly as written. Never rename, drop or add one.
- Keep product names, command names, flags, file paths and code unchanged.
- Keep the text short; it is drawn in a terminal.
- Keep a trailing period only where the English has one.

Input:
{payload}
"""


class TranslationError(Exception):
    """A reply the script will not write: wrong keys, placeholders or no JSON."""


def load_gate():
    """Import the completeness gate so both share one definition of stale."""
    spec = importlib.util.spec_from_file_location("mash_i18n_gate", GATE)
    if spec is None or spec.loader is None:  # pragma: no cover - broken checkout
        raise SystemExit(f"translate: cannot load the catalog gate from {GATE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def target_languages(i18n_dir: Path) -> list[tuple[str, str]]:
    """(code, own name) for every language the table lists but English."""
    rows = read_json(i18n_dir / "languages.json")
    return [
        (row["code"], row["name"])
        for row in rows
        if isinstance(row, dict) and row.get("code") and row.get("code") != "en"
    ]


def pending_keys(english: dict[str, str], translated: dict, gate) -> list[str]:
    """Keys the gate would reject: missing, empty, stale or placeholder-mismatched."""
    keys: list[str] = []
    for key, source in english.items():
        entry = translated.get(key)
        text = entry.get("text") if isinstance(entry, dict) else None
        if (
            not isinstance(text, str)
            or not text
            or entry.get("source_hash") != gate.source_hash(source)
            or set(gate.PLACEHOLDER.findall(text)) != set(gate.PLACEHOLDER.findall(source))
        ):
            keys.append(key)
    return keys


def build_prompt(name: str, code: str, entries: dict[str, str]) -> str:
    payload = json.dumps(entries, ensure_ascii=False, indent=2)
    return PROMPT.format(name=name, code=code, payload=payload)


def reply_object(raw: str) -> dict:
    """The JSON object in a translator reply, tolerating a fenced or chatty one."""
    text = raw.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
        text = text.rsplit("```", 1)[0].strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            raise TranslationError(f"translator did not reply with JSON: {raw.strip()[:200]!r}")
        try:
            data = json.loads(text[start : end + 1])
        except json.JSONDecodeError as exc:
            raise TranslationError(f"translator reply is not valid JSON: {exc}")
    if not isinstance(data, dict):
        raise TranslationError("translator reply is not a JSON object")
    return data


def validate(reply: dict, english: dict[str, str], keys: list[str], gate) -> dict[str, str]:
    """Texts for ``keys``, or a TranslationError naming the offending key."""
    if set(reply) != set(keys):
        missing = sorted(set(keys) - set(reply))
        extra = sorted(set(reply) - set(keys))
        raise TranslationError(
            f"translator returned the wrong keys (missing {missing}, unexpected {extra})"
        )
    texts: dict[str, str] = {}
    for key in keys:
        value = reply[key]
        if not isinstance(value, str) or not value.strip():
            raise TranslationError(f"translator returned no text for {key}")
        expected = set(gate.PLACEHOLDER.findall(english[key]))
        actual = set(gate.PLACEHOLDER.findall(value))
        if expected != actual:
            raise TranslationError(
                f"translator changed the placeholders of {key}: "
                f"expected {sorted(expected)}, got {sorted(actual)}"
            )
        texts[key] = value
    return texts


def translate(command: str, prompt: str) -> str:
    argv = shlex.split(command)
    try:
        result = subprocess.run(argv, input=prompt, capture_output=True, text=True)
    except OSError as exc:
        raise TranslationError(f"cannot run the translator {command!r}: {exc}")
    if result.returncode != 0:
        raise TranslationError(
            f"translator exited {result.returncode}: {result.stderr.strip()[:400]}"
        )
    return result.stdout


def merged(existing: dict, english: dict[str, str], fresh: dict[str, str], gate) -> dict:
    """The catalog with kept entries in place, new ones appended, extras dropped."""
    out: dict = {}
    for key, entry in existing.items():
        if key not in english:
            continue  # a translation-only key is a gate failure; the source wins
        if key in fresh:
            out[key] = {"text": fresh[key], "source_hash": gate.source_hash(english[key])}
        else:
            out[key] = entry
    for key in english:
        if key not in out:
            out[key] = {"text": fresh[key], "source_hash": gate.source_hash(english[key])}
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Translate Mash's message catalogs.")
    parser.add_argument(
        "--i18n-dir",
        type=Path,
        default=I18N,
        help="catalog root holding languages.json and messages/ (default: packaging/i18n)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"keys per translator call (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument(
        "--translator",
        default=DEFAULT_TRANSLATOR,
        help=f"command reading the prompt on stdin and printing JSON (default: {DEFAULT_TRANSLATOR!r})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="list the missing and stale keys without calling the translator",
    )
    args = parser.parse_args(argv)

    gate = load_gate()
    i18n_dir = args.i18n_dir.resolve()
    messages = i18n_dir / "messages"
    if not messages.is_dir():
        print(f"translate: no catalogs at {messages}", file=sys.stderr)
        return 1
    targets = target_languages(i18n_dir)
    batch_size = max(1, args.batch_size)

    writes: list[tuple[Path, dict]] = []
    calls = 0
    listed = 0
    for component_dir in sorted(path for path in messages.iterdir() if path.is_dir()):
        if not (component_dir / "en.json").is_file():
            print(f"translate: {component_dir.name} has no en.json", file=sys.stderr)
            return 1
        english = {
            key: value
            for key, value in read_json(component_dir / "en.json").items()
            if isinstance(value, str)
        }
        for code, name in targets:
            path = component_dir / f"{code}.json"
            existing = read_json(path) if path.is_file() else {}
            if not isinstance(existing, dict):
                existing = {}
            keys = pending_keys(english, existing, gate)
            if not keys:
                continue
            print(f"{component_dir.name}/{code}: {len(keys)} key(s) to translate")
            listed += 1
            if args.dry_run:
                for key in keys:
                    print(f"  {key}")
                continue
            fresh: dict[str, str] = {}
            for start in range(0, len(keys), batch_size):
                batch = keys[start : start + batch_size]
                try:
                    reply = reply_object(
                        translate(
                            args.translator,
                            build_prompt(name, code, {key: english[key] for key in batch}),
                        )
                    )
                    fresh.update(validate(reply, english, batch, gate))
                except TranslationError as exc:
                    print(f"translate: {component_dir.name}/{code}: {exc}", file=sys.stderr)
                    print("translate: nothing written; fix the translator and run again", file=sys.stderr)
                    return 1
                calls += 1
            writes.append((path, merged(existing, english, fresh, gate)))

    if args.dry_run:
        if not listed:
            print("translate: every catalog is complete")
        return 0
    for path, data in writes:
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not writes:
        print("translate: every catalog is complete")
        return 0
    print(f"translate: wrote {len(writes)} catalog(s) using {calls} translator call(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
