"""Contract tests for the pinned-artifact manifest.

Run with: python3 packaging/tests/test_assets.py
"""

import json
import subprocess
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


class HostReferenceTest(unittest.TestCase):
    def test_host_reference_versions_are_not_pins(self):
        manifest = assets.Manifest.load()
        pinned = {name for name, c in manifest.components.items() if c["strategy"] != "package"}
        self.assertEqual(pinned, set(manifest.pin_order))
        for name, component in manifest.components.items():
            if component["strategy"] != "package":
                continue
            with self.subTest(component=name):
                self.assertNotIn("version", component)
                self.assertTrue(component["referenceVersion"])
                with self.assertRaises(assets.AssetError):
                    manifest.version(name)
                resolved = manifest.resolve(name, "macos-arm64")
                self.assertNotIn("version", resolved)
                self.assertEqual(component["referenceVersion"], resolved["reference_version"])

    def test_host_resolution_still_works_without_a_version(self):
        result = subprocess.run(
            [sys.executable, str(PACKAGING / "assets.py"), "resolve-shell", "jq", "linux-amd64"],
            capture_output=True, text=True, check=True,
        )
        spec = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual("package", spec["STRATEGY"])
        self.assertIn("REFERENCE_VERSION", spec)
        self.assertNotIn("VERSION", spec)
        components = subprocess.run(
            [sys.executable, str(PACKAGING / "assets.py"), "components", "macos-arm64"],
            capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        self.assertIn("jq", components)  # references remain in the inventory


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

    def test_install_specs_carry_the_pinned_version(self):
        """A bare name installs whatever is current, so every installer gets one."""
        for name in self.manifest.pin_order:
            strategy = self.manifest.strategy(name)
            if strategy not in ("npm", "pip"):
                continue
            with self.subTest(component=name):
                package = self.manifest.components[name].get("package") or name
                version = self.manifest.version(name)
                self.assertEqual(
                    f"{package}{'@' if strategy == 'npm' else '=='}{version}",
                    self.manifest.install_spec(name, "macos-arm64"),
                )

    def test_host_package_strategy_refuses_a_spec(self):
        """jq comes from the platform; returning "jq" would pin nothing."""
        with self.assertRaises(assets.AssetError):
            self.manifest.install_spec("jq", "macos-arm64")

    def test_shared_npm_package_names_are_spelled_out(self):
        """The npm package can differ from the component id; the spec must use it."""
        self.assertEqual(
            "@tailwindcss/language-server@0.16.0",
            self.manifest.install_spec("tailwindcss-language-server", "linux-amd64"),
        )

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

    def test_every_component_the_macos_build_stages_resolves_for_macos(self):
        """A refactor can make the build read the manifest while the manifest
        still has only Linux artifacts. Version-only checks all pass, and the
        first real build aborts -- exactly what happened to rust/go here.

        This enumerates the components the macOS adapter stages, and resolves
        each against its actual target, not just its version. The build and
        this list must move together.
        """
        for name in (
            "rust", "go", "node", "python", "herdr", "lazygit", "lazydocker",
            "pet", "atuin", "starship", "viu", "zsh-autosuggestions", "fresh",
        ):
            with self.subTest(component=name):
                self.assertTrue(self.manifest.applies_to(name, "macos-arm64"))
                spec = self.manifest.resolve(name, "macos-arm64")
                self.assertRegex(spec["sha256"], r"^[0-9a-f]{64}$")
                self.assertTrue(spec["url"].startswith("https://"))

    def test_cua_driver_pins_both_linux_architectures(self):
        for target in LINUX:
            with self.subTest(target=target):
                spec = self.manifest.resolve("cua-driver", target)
                self.assertEqual("cua-driver", spec["component"])
                self.assertIn("linux", spec["url"])

    def test_development_tools_pin_every_architecture(self):
        """These four were Linux-only pins; macOS installed them from Homebrew.

        An unversioned formula cannot honour the manifest, so each now carries a
        macOS artifact too and every target must resolve a checksummed one.
        """
        for name in ("sentrux", "marksman", "texlab", "latexindent", "rust-analyzer"):
            self.assertEqual("binary", self.manifest.strategy(name))
            for target in ALL_TARGETS:
                with self.subTest(component=name, target=target):
                    self.assertTrue(self.manifest.applies_to(name, target))
                    spec = self.manifest.resolve(name, target)
                    self.assertRegex(spec["sha256"], r"^[0-9a-f]{64}$")
                    if name == "sentrux":
                        self.assertRegex(spec["grammars_sha256"], r"^[0-9a-f]{64}$")

    def test_macos_artifacts_are_macos_builds(self):
        """A Linux asset resolved for macOS would download and never run."""
        for name in ("sentrux", "marksman", "texlab", "latexindent", "rust-analyzer"):
            with self.subTest(component=name):
                url = self.manifest.resolve(name, "macos-arm64")["url"]
                self.assertNotIn("linux", url.lower())
                self.assertRegex(url.lower(), r"macos|darwin|apple")


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

    def test_host_reference_cannot_be_mislabeled_as_a_pin(self):
        def mutate(data):
            data["components"]["jq"]["version"] = "1.8.1"
            data["pinOrder"].append("jq")

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("jq: host packages use referenceVersion" in p for p in problems))
        self.assertTrue(any("jq: host reference must not appear in pinOrder" in p for p in problems))

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

    def test_missing_sentrux_grammar_checksum_is_reported(self):
        def mutate(data):
            del data["components"]["sentrux"]["artifacts"]["linux-arm64"]["grammars_sha256"]

        problems = self._manifest(mutate).problems()
        self.assertTrue(any("sentrux" in p and "linux-arm64" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
