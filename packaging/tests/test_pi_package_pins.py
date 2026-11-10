"""The seeded Pi settings must name the versions the build actually installs.

`mash_pi_packages` resolves every bundled Pi package from packaging/assets.json,
but packaging/defaults/pi/settings.json repeats each `npm:<name>@<version>` by
hand. Nothing tied the two together, so bumping a pin left settings.json naming
the previous version: `pi list` then resolves a specifier the bundle does not
contain. Caught when pi-ask-user moved to 0.17.0 and settings.json still said
0.16.0.
"""

import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "packaging/defaults/pi/settings.json"
ASSETS = ROOT / "packaging/assets.json"
BUILD_COMMON = ROOT / "packaging/build-common.sh"


def split_specifier(specifier):
    """`npm:<name>@<version>` -> (name, version), keeping a scope's leading @."""
    body = specifier[len("npm:"):]
    at = body.rfind("@")
    if at <= 0:
        return body, ""
    return body[:at], body[at + 1:]


def pinned_versions():
    """npm package name -> pinned version, for every bundled npm component."""
    components = json.loads(ASSETS.read_text())["components"]
    return {
        entry.get("package", name): entry["version"]
        for name, entry in components.items()
        if entry.get("strategy") == "npm"
    }


def package_names():
    """assets.json component id -> the npm package it installs."""
    components = json.loads(ASSETS.read_text())["components"]
    return {
        name: entry.get("package", name)
        for name, entry in components.items()
        if entry.get("strategy") == "npm"
    }


class PiPackagePinsTest(unittest.TestCase):
    def test_settings_packages_match_the_manifest(self):
        pinned = pinned_versions()
        packages = json.loads(SETTINGS.read_text())["packages"]
        self.assertTrue(packages)
        for specifier in packages:
            with self.subTest(specifier=specifier):
                self.assertTrue(specifier.startswith("npm:"), "only npm specifiers are pinned here")
                name, version = split_specifier(specifier)
                self.assertIn(name, pinned, f"{name} is not an npm component in assets.json")
                self.assertEqual(
                    version,
                    pinned[name],
                    f"{name} is pinned at {pinned[name]} but settings.json asks for {version}",
                )

    def test_every_installed_package_is_seeded(self):
        """A package the build installs but settings.json omits never loads."""
        loop = re.search(r"for component in ([^;]+); do", BUILD_COMMON.read_text())
        self.assertIsNotNone(loop)
        installed = loop.group(1).split()
        names = package_names()
        seeded = {split_specifier(specifier)[0] for specifier in json.loads(SETTINGS.read_text())["packages"]}
        for component in installed:
            # pi, pi-codemode and pi-ai are the agent itself and its runtime
            # dependencies, not extensions a settings.json lists.
            if component in {"pi", "pi-codemode", "pi-ai"}:
                continue
            with self.subTest(component=component):
                package = names.get(component, component)
                self.assertIn(package, seeded, f"{package} is installed but not seeded in settings.json")

    def test_the_nested_pi_ai_is_the_pinned_copy_and_not_a_second_one(self):
        """The model catalog loads the copy nested under the Pi package.

        Copied, that shipped a second 96 MB runtime inside the app; symlinked,
        the pinned hoisted package stays the only copy. Pinned at all because
        Pi declares pi-ai as an open range: 1.5.1 renamed a provider and every
        artifact job of the 0.4.1 release failed on stale wizard metadata.
        """
        build = BUILD_COMMON.read_text()
        self.assertIn('ln -s "$pi_ai_root" "$pi_ai_nested"', build)
        self.assertNotIn('cp -R "$pi_ai_root" "$pi_ai_nested"', build)
        loop = re.search(r"for component in ([^;]+); do", build)
        self.assertIsNotNone(loop)
        self.assertIn("pi-ai", loop.group(1).split())
        self.assertIn("@earendil-works/pi-ai", pinned_versions())


if __name__ == "__main__":
    unittest.main()
