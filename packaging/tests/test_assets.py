"""Contract tests for the pinned-artifact manifest.

Run with: python3 packaging/tests/test_assets.py
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PACKAGING))

import assets

PINS = PACKAGING / "pins.txt"
MANIFEST = PACKAGING / "assets.json"

LINUX = ("linux-amd64", "linux-arm64")
ALL_TARGETS = ("macos-arm64", "linux-amd64", "linux-arm64")


class ManifestIntegrityTest(unittest.TestCase):
    def setUp(self):
        self.manifest = assets.Manifest.load()

    def test_shipped_manifest_is_valid(self):
        self.assertEqual([], self.manifest.problems())

    def test_every_downloaded_artifact_pins_a_checksum_and_member(self):
        for name, component in self.manifest.components.items():
            if component.get("strategy") not in assets.DOWNLOADED:
                continue
            for target, spec in (component.get("artifacts") or {}).items():
                if target == "*":
                    continue
                with self.subTest(component=name, target=target):
                    self.assertTrue(spec.get("url"), "artifact has no url")
                    self.assertRegex(spec.get("sha256", ""), r"^[0-9a-f]{64}$")
                    self.assertIn(spec.get("archive"), assets.ARCHIVE_REQUIREMENTS)
                    self.assertTrue(spec.get("member"), "artifact has no member")

    def test_every_pin_has_a_version(self):
        for name in self.manifest.pin_order:
            with self.subTest(component=name):
                self.assertTrue(self.manifest.version(name))


class PinProjectionTest(unittest.TestCase):
    def test_projection_matches_the_committed_pin_file(self):
        manifest = assets.Manifest.load()
        self.assertEqual([], manifest.pin_problems(PINS))

    def test_projection_is_name_space_version_per_line(self):
        manifest = assets.Manifest.load()
        lines = manifest.pin_text().splitlines()
        self.assertEqual(len(manifest.pin_order), len(lines))
        for line in lines:
            name, version = line.split(" ", 1)
            self.assertEqual(name, name.strip())
            self.assertNotIn(" ", version)

    def test_drift_is_reported_with_the_offending_line(self):
        manifest = assets.Manifest.load()
        with tempfile.TemporaryDirectory() as tmp:
            drifted = Path(tmp) / "pins.txt"
            drifted.write_text(PINS.read_text().replace("herdr 0.9.3", "herdr 0.9.2"))
            problems = manifest.pin_problems(drifted)
        self.assertTrue(problems)
        self.assertTrue(any("herdr" in problem for problem in problems))


class TargetResolutionTest(unittest.TestCase):
    def setUp(self):
        self.manifest = assets.Manifest.load()

    def test_each_supported_target_resolves_its_own_exact_artifact(self):
        for target in ALL_TARGETS:
            with self.subTest(target=target):
                spec = self.manifest.resolve("node", target)
                self.assertEqual(target, spec["target"])
                self.assertIn(spec["url"], json.dumps(spec))

    def test_resolution_differs_between_architectures(self):
        amd64 = self.manifest.resolve("node", "linux-amd64")
        arm64 = self.manifest.resolve("node", "linux-arm64")
        self.assertNotEqual(amd64["url"], arm64["url"])
        self.assertNotEqual(amd64["sha256"], arm64["sha256"])

    def test_unknown_component_never_falls_back_to_a_host_binary(self):
        with self.assertRaises(assets.AssetError) as caught:
            self.manifest.resolve("definitely-not-a-pin", "linux-amd64")
        self.assertIn("definitely-not-a-pin", str(caught.exception))

    def test_target_aliases_match_the_canonical_names(self):
        for alias, canonical in (
            ("darwin-arm64", "macos-arm64"),
            ("macos-aarch64", "macos-arm64"),
            ("linux-x64", "linux-amd64"),
            ("linux-x86_64", "linux-amd64"),
            ("Linux-ARM64", "linux-arm64"),
        ):
            with self.subTest(alias=alias):
                self.assertEqual(canonical, assets.normalise_target(alias))

    def test_unsupported_target_is_refused_by_name(self):
        for bad in ("freebsd-amd64", "linux-riscv64", "windows-amd64"):
            with self.subTest(target=bad), self.assertRaises(assets.AssetError):
                self.manifest.resolve("node", bad)

    def test_linux_covers_both_architectures_for_every_downloaded_capability(self):
        for name, component in self.manifest.components.items():
            if component.get("strategy") not in assets.DOWNLOADED:
                continue
            limited = component.get("targets")
            if limited is not None:
                continue
            for target in LINUX:
                with self.subTest(component=name, target=target):
                    spec = self.manifest.resolve(name, target)
                    self.assertIn(spec["sha256"], json.dumps(spec))

    def test_cua_driver_pins_both_linux_architectures(self):
        for target in LINUX:
            with self.subTest(target=target):
                spec = self.manifest.resolve("cua-driver", target)
                self.assertEqual("cua-driver", spec["component"])
                self.assertIn("linux", spec["url"])


class FailurePathsTest(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(MANIFEST.read_text())

    def _manifest(self, mutate):
        data = json.loads(json.dumps(self.data))
        mutate(data)
        return assets.Manifest(data)

    def test_malformed_hash_names_component_and_target(self):
        def mutate(data):
            data["components"]["node"]["artifacts"]["linux-arm64"]["sha256"] = "abc123"

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("node" in p and "linux-arm64" in p for p in problems), problems)

    def test_missing_linux_artifact_is_reported_not_skipped(self):
        def mutate(data):
            del data["components"]["cua-driver"]["artifacts"]["linux-arm64"]

        manifest = self._manifest(mutate)
        problems = manifest.problems()
        self.assertTrue(any("cua-driver" in p and "linux-arm64" in p for p in problems), problems)
        with self.assertRaises(assets.AssetError):
            manifest.resolve("cua-driver", "linux-arm64")

    def test_duplicate_pin_is_reported(self):
        def mutate(data):
            data["pinOrder"].append("node")

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("duplicates" in p and "node" in p for p in problems), problems)

    def test_pin_without_component_is_reported(self):
        def mutate(data):
            data["pinOrder"].append("ghost-of-a-pin")

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("ghost-of-a-pin" in p for p in problems), problems)

    def test_artifact_without_member_is_reported(self):
        def mutate(data):
            del data["components"]["lazygit"]["artifacts"]["linux-amd64"]["member"]

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("lazygit" in p and "linux-amd64" in p for p in problems), problems)

    def test_unknown_archive_kind_is_reported(self):
        def mutate(data):
            data["components"]["pet"]["artifacts"]["linux-amd64"]["archive"] = "rar"

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("pet" in p and "linux-amd64" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
