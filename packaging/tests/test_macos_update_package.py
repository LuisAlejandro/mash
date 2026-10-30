"""The macOS updater must ship as one signed unit, without entering Linux."""

import pathlib
import plistlib
import re
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MacOSUpdatePackageTest(unittest.TestCase):
    def test_tcc_resource_entitlements_reach_the_bundle_macos_attributes(self):
        """Dictation depends on two things only the bundle can provide.

        macOS attributes a microphone prompt raised by a program inside Mash to
        the outermost bundle, so Mash.app -- not the nested Ghostty -- has to
        carry the hardened-runtime entitlement and the purpose string. Missing
        either does not fail loudly: tccd logs "Policy disallows prompt" and
        denies, CoreAudio reports the denial as a silent stream, and pi-voice
        transcribes 100% digital silence as "no speech detected".
        """
        entitlements = plistlib.loads((ROOT / "packaging/entitlements.plist").read_bytes())
        self.assertIs(entitlements.get("com.apple.security.device.audio-input"), True)

        build = (ROOT / "packaging/build.sh").read_text()
        info_plist = build.split('cat >"$app/Contents/Info.plist" <<EOF', 1)[1]
        info_plist = info_plist.split("\nEOF", 1)[0]
        self.assertIn("NSMicrophoneUsageDescription", info_plist)

    def test_macos_build_points_pi_at_the_mash_project_dir(self):
        """The macOS build installs Pi itself, not through mash_stage_runtimes.

        mash_set_pi_project_dir is what makes Pi read a project's .mash/ instead
        of .pi/, and only the shared runtime stager called it, so the Mac app
        silently kept reading .pi/. It must run right after the Pi install, and
        before the runtime check, so a Pi that ignores the key fails the build.
        """
        build = (ROOT / "packaging/build.sh").read_text()
        install = build.index('--prefix "$app/Contents/Resources/node" \\\n  $pi_packages')
        set_dir = build.index('mash_set_pi_project_dir "$app/Contents/Resources"')
        runtime = build.index('"$root/packaging/tests/test_pi_runtime.sh" "$app/Contents/Resources"')
        self.assertLess(install, set_dir)
        self.assertLess(set_dir, runtime)

    def test_app_executable_is_compiled_so_it_can_carry_entitlements(self):
        """Mash.app's executable must be a Mach-O, not the launcher script.

        macOS checks a microphone request against Mash.app's own executable.
        A signature embeds entitlements only in a Mach-O, so while the executable
        was packaging/mash itself, Mash.app carried none and dictation was
        refused silently. build.sh compiles packaging/mash-launcher.c into
        Contents/MacOS/mash and installs the script beside the other helpers.
        """
        build = (ROOT / "packaging/build.sh").read_text()
        self.assertIn('-o "$app/Contents/MacOS/mash"', build)
        self.assertIn('"$root/packaging/mash-launcher.c"', build)
        self.assertIn(
            'cp "$root/packaging/mash" "$app/Contents/Resources/bin/mash-launch"', build
        )
        self.assertNotIn('cp "$root/packaging/mash" "$app/Contents/MacOS/mash"', build)
        launcher = (ROOT / "packaging/mash-launcher.c").read_text()
        self.assertIn('"%s/../Resources/bin/mash-launch"', launcher)
        # The script now lives two levels below Contents, and derives every
        # bundle path from ROOT.
        script = (ROOT / "packaging/mash").read_text()
        self.assertIn('ROOT="$(cd "$(dirname "$0")/../.." && pwd)"', script)

    def test_macos_launcher_stages_everything_it_sources(self):
        build = (ROOT / "packaging/build.sh").read_text()
        launcher = (ROOT / "packaging/mash").read_text()
        required = re.findall(r'^source "\$ROOT/Resources/bin/([^"/]+)"$', launcher, re.MULTILINE)
        self.assertTrue(required)
        for name in required:
            with self.subTest(name=name):
                self.assertIn(
                    f'cp "$root/packaging/{name}" "$app/Contents/Resources/bin/{name}"',
                    build,
                )

    def test_macos_payload_stages_notice_verify_apply_and_native_swap(self):
        build = (ROOT / "packaging/build.sh").read_text()
        helpers = build.split("ship_helpers=(", 1)[1].split("\n)", 1)[0].split()
        self.assertTrue(
            {"mash-update-notice", "mash-update-verify", "mash-update-apply"}.issubset(helpers)
        )
        self.assertIn("packaging/helpers/mash-update-swap.c", build)
        self.assertIn("-mmacosx-version-min=14.0", build)
        self.assertIn('"$app/Contents/Resources/bin/mash-update-swap"', build)

    def test_linux_payload_keeps_apt_and_excludes_macos_helpers(self):
        build = (ROOT / "packaging/build-common.sh").read_text()
        for name in ("mash-update-verify", "mash-update-apply", "mash-update-swap.c"):
            self.assertIn(name, build)
        launcher = (ROOT / "packaging/herdr-pane").read_text()
        self.assertIn('"$bin_dir/mash-update-notice" "$res" "$home/.mash"', launcher)
        self.assertNotIn('"$bin_dir/mash-update-verify"', launcher)

    def test_github_mcp_follows_sign_in_on_every_launch(self):
        build = (ROOT / "packaging/build.sh").read_text()
        helpers = build.split("ship_helpers=(", 1)[1].split("\n)", 1)[0].split()
        self.assertIn("mash-github-mcp", helpers)
        launcher = (ROOT / "packaging/herdr-pane").read_text()
        self.assertIn('"$bin_dir/mash-github-mcp" "$home/.mash"', launcher)
        wizard = (ROOT / "packaging/wizard/main.rs").read_text()
        self.assertIn('join("bin/mash-github-mcp")', wizard)
        # The build guard rejects token shapes, not the word "github".
        carry = (ROOT / "packaging/carry.sh").read_text()
        self.assertNotIn("grep -q 'github' \"$pi/mcp.json\"", carry)

    def test_popup_plugin_ships_to_both_platforms(self):
        manifest = tomllib.loads(
            (ROOT / "packaging/plugins/mash-update-notice/herdr-plugin.toml").read_text()
        )
        self.assertEqual(set(manifest["platforms"]), {"macos", "linux"})
        self.assertEqual({p["id"] for p in manifest["panes"]}, {"notice", "update", "updated"})
        self.assertEqual(manifest["panes"][0]["width"], 56)
        self.assertIn(
            'mash_copy_tree "$src/mash-update-notice" "$plugins/mash-update-notice"',
            (ROOT / "packaging/carry.sh").read_text(),
        )


if __name__ == "__main__":
    unittest.main()
