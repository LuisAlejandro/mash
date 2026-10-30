"""The macOS updater must ship as one signed unit, without entering Linux."""

import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MacOSUpdatePackageTest(unittest.TestCase):
    def test_tcc_resource_entitlements_reach_the_bundle_macos_attributes(self):
        """Dictation depends on two things only the app's signature can provide.

        macOS attributes a microphone prompt raised by a program inside Mash to
        the app, so Mash.app has to carry the hardened-runtime entitlement and
        the purpose string. Missing either does not fail loudly: tccd logs
        "Policy disallows prompt" and denies, CoreAudio reports the denial as a
        silent stream, and pi-voice transcribes 100% digital silence as "no
        speech detected".
        """
        entitlements = plistlib.loads((ROOT / "packaging/entitlements.plist").read_bytes())
        self.assertIs(entitlements.get("com.apple.security.device.audio-input"), True)

        build = (ROOT / "packaging/build.sh").read_text()
        self.assertIn("Set :NSMicrophoneUsageDescription A program running within Mash", build)
        release = (ROOT / "packaging/release.sh").read_text()
        self.assertIn(
            'sign_item "$download/Mash.app" "$root/packaging/entitlements.plist"', release
        )

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

    def test_app_is_the_terminal_and_hands_its_launch_to_the_setup(self):
        """Mash.app is one app: its executable is the terminal.

        macOS saves and reopens the app that owns the windows, so after a
        restart it reopened the nested terminal directly and the terminal, with
        no Mash environment, refused to start. The terminal is now the bundle,
        and it execs Resources/bin/mash-launch before it initializes; the script
        execs it back with the environment ready. A compiled launcher, a nested
        "Mash Terminal.app" and an `open -na` handoff must not come back.
        """
        build = (ROOT / "packaging/build.sh").read_text()
        self.assertIn('ditto "$ghostty_src" "$app"', build)
        self.assertIn("Set :CFBundleIdentifier app.mash'", build)
        self.assertIn(
            'cp "$root/packaging/mash" "$app/Contents/Resources/bin/mash-launch"', build
        )
        self.assertNotIn("mash-launcher.c", build)
        self.assertNotIn("Mash Terminal.app", build)
        self.assertFalse((ROOT / "packaging/mash-launcher.c").exists())

        script = (ROOT / "packaging/mash").read_text()
        self.assertIn('ROOT="$(cd "$(dirname "$0")/../.." && pwd)"', script)
        self.assertIn('terminal="$ROOT/MacOS/mash-terminal"', script)
        self.assertIn('exec "$terminal" "${args[@]+"${args[@]}"}"', script)
        self.assertNotIn('exec "$terminal" "${args[@]}"', script)
        self.assertNotIn("open -na", script)

    def test_dock_launch_with_no_arguments_reaches_the_terminal(self):
        """A Dock click passes no arguments, and the setup must still hand off.

        macOS runs the setup under /bin/bash 3.2, where expanding an empty array
        under `set -u` is an "unbound variable" error. The setup finished and
        then died at the handoff, so clicking the icon did nothing. This runs
        the real script, with no arguments, against a stub terminal.
        """
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            bin_dir = tmp / "App/Contents/Resources/bin"
            macos = tmp / "App/Contents/MacOS"
            fake = tmp / "fake"
            for d in (bin_dir, macos, fake, tmp / "home"):
                d.mkdir(parents=True)
            for name in ("lib.sh", "launch-common.sh"):
                shutil.copy(ROOT / "packaging" / name, bin_dir / name)
            shutil.copy(ROOT / "packaging/mash", bin_dir / "mash-launch")
            out = tmp / "out"
            # The stub terminal records that the handoff happened, and how.
            terminal = macos / "mash-terminal"
            terminal.write_text(
                f'#!/bin/bash\nprintf "argc=%s err=%s\\n" "$#" "${{MASH_SETUP_ERROR:-}}" >"{out}"\n'
            )
            terminal.chmod(0o755)
            # mash_real_home asks the directory service; point it at the scratch home.
            dscl = fake / "dscl"
            dscl.write_text(f'#!/bin/sh\necho "NFSHomeDirectory: {tmp / "home"}"\n')
            dscl.chmod(0o755)
            env = {"HOME": str(tmp / "home"), "PATH": f"{fake}:/usr/bin:/bin:/usr/sbin"}
            subprocess.run(["/bin/bash", str(bin_dir / "mash-launch")], env=env, check=False)
            self.assertTrue(out.exists(), "the setup never handed off to the terminal")
            self.assertEqual(out.read_text(), "argc=0 err=\n")

    def test_bytecode_is_refused_before_the_setup_runs_python(self):
        """The setup's own seeding runs the bundled Python.

        With PYTHONDONTWRITEBYTECODE exported only after mash_seed_all, the
        first launch of a fresh install wrote encodings/__pycache__ into the
        signed bundle and broke its seal.
        """
        script = (ROOT / "packaging/mash").read_text()
        self.assertLess(
            script.index("export PYTHONDONTWRITEBYTECODE=1"),
            script.index('mash_seed_all "$ROOT/Resources"'),
        )

    def test_macos_launcher_stages_everything_it_sources(self):
        build = (ROOT / "packaging/build.sh").read_text()
        launcher = (ROOT / "packaging/mash").read_text()
        required = re.findall(r'^source "\$ROOT/Resources/bin/([^"/]+)"', launcher, re.MULTILINE)
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
