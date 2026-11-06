"""Seeded tool configs follow the language the wizard recorded.

mash-seed-sync reads `setup/language` the way mash_isolate does and renders the
three seeded files that ship a language: Fresh's `locale`, lazydocker's
`gui.language`, and the Mash-owned labels in the Herdr config. English (and an
install from before the language existed) seeds exactly what Mash seeded before,
because a language change must never rewrite an English install's files. Both
platforms run, since the Herdr and Fresh templates are platform-specific.

The language codes asserted here come from packaging/i18n/languages.json, the
table KTD1 makes authoritative, so a spelling cannot drift away from it.

Run with: python3 packaging/tests/test_seed_language.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
DEFAULTS = PACKAGING / "defaults"
I18N = PACKAGING / "i18n"
SYNC = PACKAGING / "helpers" / "mash-seed-sync"

PLATFORMS = ("Darwin", "Linux")
LANGUAGES = {row["code"]: row for row in json.loads((I18N / "languages.json").read_text(encoding="utf-8"))}


def herdr_text(code, key):
    """One Herdr label in one language, straight from its catalog."""
    catalog = json.loads((I18N / "messages" / "herdr" / f"{code}.json").read_text(encoding="utf-8"))
    entry = catalog[key]
    return entry["text"] if isinstance(entry, dict) else entry


class Seeded:
    """A resource root and data folder shaped like an installed Mash."""

    def __init__(self, test, platform="Darwin", language=None):
        self._tmp = tempfile.TemporaryDirectory()
        test.addCleanup(self._tmp.cleanup)
        self.platform = platform
        self.root = Path(self._tmp.name)
        self.res = self.root / "res"
        self.data = self.root / "data"
        self.record = self.data / "local" / "state" / "seeded.json"
        self.language_file = self.data / "setup" / "language"
        self.fresh = self.data / "config" / "fresh" / "config.json"
        self.lazydocker = self.data / "config" / "lazydocker" / "config.yml"
        self.herdr = self.data / "config" / "herdr" / "config.toml"
        self.build()
        if language is not None:
            self.set_language(language)

    def build(self):
        (self.res / "defaults").mkdir(parents=True)
        (self.res / "VERSION").write_text("1.0.0\n", encoding="utf-8")
        # carry.sh stages this inventory into every bundle beside the defaults.
        (self.res / "defaults" / "optional-programming.txt").write_text("", encoding="utf-8")
        for name in ("herdr", "fresh", "lazydocker"):
            shutil.copytree(DEFAULTS / name, self.res / "defaults" / name)
        # build-common.sh stages packaging/i18n into the bundle the same way.
        shutil.copytree(I18N, self.res / "i18n")
        self.data.mkdir(parents=True)

    def set_language(self, code):
        self.language_file.parent.mkdir(parents=True, exist_ok=True)
        self.language_file.write_text(f"language={code}\n", encoding="utf-8")

    def set_mode(self, mode):
        path = self.data / "setup" / "keybindings-mode"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"mode={mode}\n", encoding="utf-8")

    def drop_catalogs(self):
        shutil.rmtree(self.res / "i18n")

    def sync(self):
        proc = subprocess.run(
            [str(SYNC), str(self.res), str(self.data)],
            env={**os.environ, "MASH_SEED_PLATFORM": self.platform},
            capture_output=True,
            text=True,
            check=False,
        )
        assert proc.returncode == 0, proc.stderr
        return proc.stdout

    def fresh_config(self):
        return json.loads(self.fresh.read_text(encoding="utf-8"))

    def herdr_config(self):
        return tomllib.loads(self.herdr.read_text(encoding="utf-8"))

    def selection(self):
        return json.loads(self.record.read_text(encoding="utf-8"))["selection"]

    def rendered(self):
        """The three rendered files, with this fixture's temp root blanked out."""
        return tuple(
            path.read_text(encoding="utf-8").replace(str(self.root), "<root>")
            for path in (self.herdr, self.fresh, self.lazydocker)
        )


def without_labels(herdr_text_rendered):
    """A rendered Herdr config with every translated label blanked out."""
    config = tomllib.loads(herdr_text_rendered)
    for command in config.get("keys", {}).get("command", []):
        if "description" in command:
            command["description"] = "<label>"
    if "window_title" in config.get("ui", {}):
        config["ui"]["window_title"] = "<title>"
    return config


class SeededLanguageTest(unittest.TestCase):
    def each_platform(self, check):
        for platform in PLATFORMS:
            with self.subTest(platform=platform):
                check(platform)

    def test_the_english_catalog_matches_the_shipped_labels(self):
        """The render swaps on the English text, so it has to be the defaults' text."""
        catalog = json.loads((I18N / "messages" / "herdr" / "en.json").read_text(encoding="utf-8"))
        for platform in PLATFORMS:
            suffix = ".linux" if platform == "Linux" else ""
            text = (DEFAULTS / "herdr" / f"config{suffix}.toml").read_text(encoding="utf-8")
            for key, english in catalog.items():
                with self.subTest(platform=platform, key=key):
                    self.assertIn(english, text)

    def test_english_seeds_exactly_what_mash_seeded_before(self):
        def check(platform):
            absent = Seeded(self, platform)
            absent.sync()
            chosen = Seeded(self, platform, "en")
            chosen.sync()
            uncatalogued = Seeded(self, platform, "en")
            uncatalogued.drop_catalogs()
            uncatalogued.sync()
            self.assertEqual(absent.rendered(), chosen.rendered())
            self.assertEqual(absent.rendered(), uncatalogued.rendered())
            self.assertNotIn("locale", chosen.fresh_config())
            self.assertNotIn("language:", chosen.lazydocker.read_text(encoding="utf-8"))
            self.assertIn('description = "File finder"', chosen.rendered()[0])

        self.each_platform(check)

    def test_japanese_changes_only_the_labels_mash_owns(self):
        def check(platform):
            english = Seeded(self, platform)
            english.sync()
            japanese = Seeded(self, platform, "ja")
            japanese.sync()
            self.assertEqual(japanese.fresh_config()["locale"], LANGUAGES["ja"]["fresh"])
            text = japanese.rendered()[0]
            self.assertIn(f'description = "{herdr_text("ja", "herdr.command.file-finder")}"', text)
            self.assertNotIn('description = "File finder"', text)
            # Everything but the labels is the English render, including the
            # placeholders Herdr fills in itself.
            self.assertEqual(
                without_labels(english.rendered()[0]),
                without_labels(text),
            )
            self.assertIn("{workspace}", japanese.herdr_config()["ui"]["window_title"])

        self.each_platform(check)

    def test_fresh_locale_follows_the_language_table(self):
        def check(code, platform):
            chosen = Seeded(self, platform, code)
            chosen.sync()
            self.assertEqual(chosen.fresh_config()["locale"], LANGUAGES[code]["fresh"])
            self.assertEqual(chosen.selection()["language"], code)

        for code in ("es", "pt-BR", "zh-CN"):
            for platform in PLATFORMS:
                with self.subTest(code=code, platform=platform):
                    check(code, platform)

    def test_lazydocker_names_the_languages_it_ships_and_english_otherwise(self):
        def check(platform):
            spanish = Seeded(self, platform, "es")
            spanish.sync()
            self.assertIn("language: es\n", spanish.lazydocker.read_text(encoding="utf-8"))
            self.assertEqual(LANGUAGES["es"]["lazydocker"], "es")
            thai = Seeded(self, platform, "th")
            thai.sync()
            # lazydocker ships no Thai; its fallback follows the process locale,
            # which is not the language in that case, so English is explicit.
            self.assertIn("language: en\n", thai.lazydocker.read_text(encoding="utf-8"))
            self.assertEqual(LANGUAGES["th"]["lazydocker"], "en")

        self.each_platform(check)

    def test_an_untouched_config_switches_language_on_the_next_sync(self):
        def check(platform):
            seeded = Seeded(self, platform, "es")
            seeded.sync()
            self.assertEqual(seeded.fresh_config()["locale"], "es")
            seeded.set_language("de")
            seeded.sync()
            self.assertEqual(seeded.fresh_config()["locale"], "de")
            self.assertIn(
                f'description = "{herdr_text("de", "herdr.command.source-control")}"',
                seeded.rendered()[0],
            )

        self.each_platform(check)

    # Covers AE4: a Fresh locale the user set by hand survives a language change.
    def test_a_user_edit_survives_a_language_change(self):
        def check(platform):
            seeded = Seeded(self, platform, "es")
            seeded.sync()
            config = seeded.fresh_config()
            config["locale"] = "fr"
            seeded.fresh.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
            before = seeded.fresh.read_bytes()
            seeded.set_language("de")
            seeded.sync()
            self.assertEqual(seeded.fresh.read_bytes(), before)

        self.each_platform(check)

    # Covers AE3: lazygit has no Mash config, so it follows LANG and shows its own
    # fallback language instead of failing.
    def test_no_lazygit_config_is_seeded(self):
        def check(platform):
            seeded = Seeded(self, platform, "es")
            seeded.sync()
            self.assertFalse((seeded.data / "config" / "lazygit" / "config.yml").exists())

        self.each_platform(check)

    def test_an_unknown_language_seeds_english(self):
        def check(platform):
            english = Seeded(self, platform, "en")
            english.sync()
            unknown = Seeded(self, platform, "xx")
            unknown.sync()
            self.assertEqual(unknown.rendered(), english.rendered())
            self.assertEqual(unknown.selection()["language"], "en")

        self.each_platform(check)

    def test_native_keys_join_on_the_english_labels_before_translation(self):
        def check(platform):
            seeded = Seeded(self, platform, "ja")
            seeded.set_mode("native")
            seeded.sync()
            commands = seeded.herdr_config()["keys"]["command"]
            finder = next(command for command in commands if command["key"] == "prefix+f")
            self.assertEqual(finder["description"], herdr_text("ja", "herdr.command.file-finder"))

        self.each_platform(check)


if __name__ == "__main__":
    unittest.main(verbosity=2)
