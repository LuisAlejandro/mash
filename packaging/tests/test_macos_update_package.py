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
        """Pi must read a project's .mash/ rather than .pi/ on macOS too.

        The macOS adapter used to install Pi itself and skipped
        mash_set_pi_project_dir, so the Mac app silently kept reading .pi/. It
        now goes through the shared runtime stager, which installs Pi, sets the
        key, and then proves the installed Pi honours it. Assert the ordering
        inside that one stager, since both platforms depend on it.
        """
        build = (ROOT / "packaging/build.sh").read_text()
        self.assertIn('mash_stage_runtimes "$app/Contents/Resources" "$target"', build)

        common = (ROOT / "packaging/build-common.sh").read_text()
        install = common.index("$pi_packages")
        set_dir = common.index('mash_set_pi_project_dir "$res"')
        runtime = common.index('"$root/packaging/tests/test_pi_runtime.sh" "$res"')
        self.assertLess(install, set_dir)
        self.assertLess(set_dir, runtime)

    def test_defaults_merge_with_already_staged_runtime_files(self):
        """Shared staging creates defaults/pi for typebox and the voice catalog.
        Copying the directory itself afterwards would nest defaults/defaults.
        Exercise the actual copy command against that pre-existing layout.
        """
        build = (ROOT / "packaging/build.sh").read_text()
        copy = next(line for line in build.splitlines()
                    if line.startswith('cp -R "$root/packaging/defaults'))
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            root = tmp / "source"
            app = tmp / "Mash.app"
            source = root / "packaging/defaults/pi"
            staged = app / "Contents/Resources/defaults"
            source.mkdir(parents=True)
            runtime = staged / "pi/node_modules/typebox"
            runtime.mkdir(parents=True)
            (source / "settings.json").write_text("template")
            (runtime / "package.json").write_text("runtime")
            subprocess.run(
                ["bash", "-eu", "-c", copy],
                env={"root": str(root), "app": str(app), "PATH": "/usr/bin:/bin"},
                check=True,
            )
            self.assertTrue((staged / "pi/settings.json").is_file())
            self.assertTrue((runtime / "package.json").is_file())
            self.assertFalse((staged / "defaults").exists())

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
            for name in ("lib.sh", "launch-common.sh", "mash-shell"):
                shutil.copy(ROOT / "packaging" / name, bin_dir / name)
            # Critical seed failures now reach the setup alert, so the happy
            # handoff needs a usable payload rather than silently missing defaults.
            resources = bin_dir.parent
            shutil.copytree(ROOT / "packaging/defaults", resources / "defaults", symlinks=True)
            (resources / "defaults/optional-programming.txt").write_text("")
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
            # The same real launcher must pass an actual critical failure to
            # its terminal alert instead of pretending initialization succeeded.
            (tmp / "home/.mash/config/herdr/config.toml").unlink()
            for name in ("config.toml", "config.linux.toml"):
                (resources / "defaults/herdr" / name).unlink()
            subprocess.run(["/bin/bash", str(bin_dir / "mash-launch")], env=env, check=False)
            self.assertIn("argc=0 err=Setting up ", out.read_text())

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
            {
                "mash-update-notice", "mash-update-verify", "mash-update-apply",
                "mash-update-common", "mash-update-gate",
            }.issubset(helpers)
        )
        for source in ("mash-update-swap", "mash-update-processes"):
            self.assertIn(f"packaging/helpers/{source}.c", build)
            self.assertIn(f'"$app/Contents/Resources/bin/{source}"', build)
        self.assertIn("-mmacosx-version-min=14.0", build)

    def test_detached_worker_dependencies_are_copied_out_of_the_bundle(self):
        verify = (ROOT / "packaging/helpers/mash-update-verify").read_text()
        copied = verify.split("for helper in", 2)[2].split(";", 1)[0].split()
        for helper in ("mash-update-common", "mash-update-processes", "mash-update-gate",
                       "mash-update-apply", "mash-update-swap"):
            self.assertIn(helper, copied)

    def test_native_lifecycle_patch_ships_and_is_applied_by_the_build_seam(self):
        patch = (ROOT / "packaging/patches/ghostty-update-lifecycle.patch").read_text()
        self.assertIn("macos/Sources/App/main.swift", patch)
        self.assertIn("mashUpdateObserveReadiness()", patch)
        self.assertIn(
            "ghostty-update-lifecycle.patch",
            (ROOT / "packaging/helpers/mash-ghostty-patch-menu").read_text(),
        )

    def test_linux_payload_keeps_apt_and_excludes_macos_helpers(self):
        build = (ROOT / "packaging/build-common.sh").read_text()
        for name in ("mash-update-verify", "mash-update-apply", "mash-update-common",
                     "mash-update-gate", "mash-update-processes.c", "mash-update-swap.c"):
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
