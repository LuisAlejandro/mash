"""Contract tests for the Linux packaging templates.

These run anywhere, including macOS, because they check the files a package is
built from rather than a built package. Auditing an actual .deb is
packaging/tests/verify-linux-installed.sh's job; this is the part that can fail
fast on a laptop before any Linux build runs.

Run with: python3 packaging/tests/test_linux_package.py
"""

import re
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
LINUX = PACKAGING / "linux"
BUILD = PACKAGING / "build-linux.sh"

# The package name and app id are decisions the rest of the tooling depends on,
# so they are asserted here rather than trusted to stay put.
PACKAGE_NAME = "letsmash"
APP_ID = "app.mash.Mash"


class ControlTemplateTest(unittest.TestCase):
    def setUp(self):
        self.text = (LINUX / "control.in").read_text()

    def test_package_name_avoids_ubuntus_mash_package(self):
        self.assertIn(f"Package: {PACKAGE_NAME}\n", self.text)
        self.assertNotIn("\nPackage: mash\n", self.text)

    def test_required_debian_fields_are_templated(self):
        # Depends is composed from the derived shared-library list plus the
        # runtime commands the launcher invokes, so it may hold several tokens.
        for field in ("Version", "Architecture", "Maintainer", "Installed-Size"):
            with self.subTest(field=field):
                self.assertRegex(self.text, rf"(?m)^{field}: @[A-Z_]+@$")
        self.assertRegex(self.text, r"(?m)^Depends: @[A-Z_]+@(, @[A-Z_]+@)*$")

    def test_runtime_dependencies_cover_what_the_launcher_invokes(self):
        # The launcher seeds with rsync and the desktop entry opens files with
        # xdg-open; neither is linked, so both must be declared.
        build = BUILD.read_text()
        self.assertIn("rsync", build)
        self.assertIn("xdg-utils", build)
        # The package-installed APT source is HTTPS; without CA roots apt
        # cannot verify apt.letsma.sh and silently ignores the repository.
        self.assertIn("ca-certificates", build)

    def test_description_names_the_data_folder_contract(self):
        # The single sentence a user reads before installing should say that
        # their configuration survives, because that is the promise the
        # upgrade and removal requirements make.
        self.assertIn("~/.mash", self.text)


class DesktopEntryTest(unittest.TestCase):
    def setUp(self):
        self.text = (LINUX / "app.desktop.in").read_text()

    def test_entry_is_named_for_our_app_id_not_ghostty(self):
        self.assertIn("Icon=@APPID@", self.text)
        self.assertIn("StartupWMClass=@APPID@", self.text)
        self.assertNotIn("com.mitchellh.ghostty", self.text)

    def test_visible_name_is_mash(self):
        self.assertRegex(self.text, r"(?m)^Name=Mash$")

    def test_launch_goes_through_the_private_launcher(self):
        self.assertRegex(self.text, r"(?m)^Exec=/opt/letsmash/bin/letsmash-launch")

    def test_dbus_activation_is_disabled(self):
        # A DBus-activated launch would not inherit Mash's isolated environment.
        self.assertRegex(self.text, r"(?m)^DBusActivatable=false$")

    def test_entry_declares_the_desktop_entry_spec_key(self):
        self.assertRegex(self.text, r"(?m)^\[Desktop Entry\]$")
        self.assertRegex(self.text, r"(?m)^Type=Application$")


class BuildScriptContractTest(unittest.TestCase):
    def setUp(self):
        self.text = BUILD.read_text()

    def test_build_is_pinned_to_the_supported_targets(self):
        self.assertIn("linux-amd64", self.text)
        self.assertIn("linux-arm64", self.text)
        self.assertIn("only; this is", self.text)

    def test_ghostty_is_built_without_system_layer_shell(self):
        # Ubuntu 24.04 does not package gtk4-layer-shell, so Ghostty must build
        # its own copy; dropping this flag breaks the build on the baseline.
        self.assertIn("-fno-sys=gtk4-layer-shell", self.text)

    def test_gtk_branding_and_layout_come_from_the_pinned_fork(self):
        self.assertIn('cd "$ghostty_src"', self.text)
        self.assertNotIn("ghostty-gtk-branding.patch", self.text)
        self.assertNotIn("ghostty-gtk-window-layout.patch", self.text)
        guard = (PACKAGING / "carry.sh").read_text()
        self.assertIn('pub const base_application_id = "app.mash.Mash"', guard)
        self.assertIn('pub const resource_path = "/app/mash/Mash"', guard)
        self.assertIn("grep -A1 -F '      [top]'", guard)

    def test_rpath_is_rewritten_before_packaging(self):
        # zig installs lib/libgtk4-layer-shell.so but leaves the binary looking
        # in .zig-cache, so an installed tree cannot start without this.
        self.assertIn("patchelf --set-rpath '$ORIGIN/../lib'", self.text)

    def test_upstream_ghostty_identity_is_removed(self):
        for entry in (
            "com.mitchellh.ghostty.desktop",
            "com.mitchellh.ghostty.service",
            "com.mitchellh.ghostty.metainfo.xml",
        ):
            with self.subTest(entry=entry):
                self.assertIn(entry, self.text)

    def test_package_is_built_reproducibly(self):
        self.assertIn("SOURCE_DATE_EPOCH", self.text)
        self.assertIn("--root-owner-group", self.text)

    def test_no_public_command_is_installed(self):
        # /usr/bin/mash belongs to Ubuntu's bioinformatics package, so nothing
        # is staged there. The script may mention that path in a comment; what
        # matters is that it never writes into it.
        self.assertNotIn("$stage/usr/bin", self.text)
        self.assertNotIn('mkdir -p "$stage/usr/bin"', self.text)


class SharedPayloadCatalogTest(unittest.TestCase):
    """The runtime catalog must travel with every payload, not just macOS.

    mash-voice-model reads defaults/pi/catalog from the resource root. The macOS
    adapter used to copy it itself and the Linux adapter never did, so dictation
    setup failed on Linux with "catalog.json is missing from the bundle".
    """

    def test_both_adapters_use_the_shared_stager(self):
        common = (PACKAGING / "build-common.sh").read_text()
        self.assertIn("mash_stage_pi_voice_catalog()", common)
        self.assertIn('mash_stage_pi_voice_catalog "$res"', common)
        self.assertIn(
            'mash_stage_pi_voice_catalog "$app/Contents/Resources"',
            (PACKAGING / "build.sh").read_text(),
        )

    def test_payload_verifier_requires_the_catalog(self):
        common = (PACKAGING / "build-common.sh").read_text()
        self.assertIn("defaults/pi/catalog/catalog.json", common)


class AptPublishWorkflowTest(unittest.TestCase):
    def test_publisher_accepts_release_asset_arch_names_and_pins_host_key(self):
        publisher = (PACKAGING / "apt" / "publish.sh").read_text()
        self.assertIn("*-linux-amd64.deb", publisher)
        self.assertIn("*-linux-arm64.deb", publisher)
        self.assertIn("StrictHostKeyChecking=yes", publisher)
        self.assertIn("MASH_APT_KNOWN_HOSTS_FILE", publisher)

    def test_release_is_not_public_until_apt_import_and_smoke_succeed(self):
        workflow = (PACKAGING.parent / ".github" / "workflows" / "artifacts.yml").read_text()
        publish_job = workflow.index("  publish-apt:")
        smoke = workflow.index("./packaging/tests/apt-upgrade-smoke.sh")
        release_job = workflow.index("  publish-release:")
        public_flip = workflow.index("--draft=false", release_job)
        self.assertLess(publish_job, smoke)
        self.assertLess(smoke, release_job)
        self.assertIn("needs: [setup, attach-release, publish-apt]", workflow[release_job:])
        self.assertGreater(public_flip, release_job)


class AppIdConsistencyTest(unittest.TestCase):
    """The desktop entry, the icons and the Ghostty config must agree.

    GNOME associates a window with its launcher through StartupWMClass, which
    must equal the Wayland app-id Ghostty is told to use. If these drift, the
    launcher shows a generic icon and a second window group appears.
    """

    def test_app_id_matches_the_build_script(self):
        self.assertIn(f'appid="{APP_ID}"', BUILD.read_text())

    def test_linux_ghostty_config_declares_the_same_class(self):
        config = PACKAGING / "defaults" / "ghostty" / "config.linux"
        if not config.exists():
            self.skipTest("config.linux is added by the Linux defaults unit")
        text = config.read_text()
        self.assertRegex(text, rf'(?m)^class\s*=\s*"?{re.escape(APP_ID)}"?$')


class RepositoryConfigurationTest(unittest.TestCase):
    """The package subscribes the machine to Mash's own APT repository.

    These are contract checks on the shipped maintainer scripts: what they
    write, where, and what they must never do. Auditing a real install is
    packaging/tests/verify-linux-installed.sh's job.
    """

    def setUp(self):
        self.postinst = (LINUX / "postinst").read_text()
        self.postrm = (LINUX / "postrm").read_text()
        self.keyring = (LINUX / "letsmash-archive-keyring.gpg").read_bytes()

    def test_scripts_are_executable(self):
        for name in ("postinst", "postrm"):
            with self.subTest(script=name):
                path = LINUX / name
                self.assertTrue(path.exists())
                self.assertTrue(path.stat().st_mode & 0o111, f"{name} is not executable")

    def test_source_names_the_production_repository(self):
        self.assertIn("URIs: https://apt.letsma.sh", self.postinst)
        # The suite is named for the Ubuntu baseline, not "stable": Depends are
        # derived from the build machine's libraries.
        self.assertIn("Suites: noble", self.postinst)
        self.assertIn("Components: main", self.postinst)
        self.assertIn("Architectures: @ARCH@", self.postinst)

    def test_signed_by_points_at_the_shipped_keyring(self):
        keyring_path = "/usr/share/keyrings/letsmash-archive-keyring.gpg"
        self.assertIn(f"Signed-By: {keyring_path}", self.postinst)
        self.assertTrue((LINUX / "letsmash-archive-keyring.gpg").exists())
        self.assertEqual(self.keyring[0], 0x99)

    def test_scripts_never_invoke_a_package_manager(self):
        # Configuring a source must not refresh indices or install anything: a
        # postinst that runs apt deadlocks other package operations. Comments
        # are stripped first: both scripts mention dpkg in prose to explain why
        # the keyring is package-owned.
        def code_only(text):
            return "\n".join(
                line for line in text.splitlines() if not line.lstrip().startswith("#")
            )

        for name, text in (("postinst", self.postinst), ("postrm", self.postrm)):
            code = code_only(text)
            with self.subTest(script=name):
                for command in ("apt-get", "aptitude", "dpkg "):
                    self.assertNotIn(command, code)
                self.assertIsNone(
                    re.search(r"(?m)^\s*apt\s", code),
                    f"{name} invokes apt directly",
                )

    def test_repository_is_configured_once(self):
        # A user who removes the source keeps it removed; repo_add_once is the
        # record of "we already did this", mirroring the ChatGPT package. Purge
        # deletes the record, so a later reinstall configures the source again.
        self.assertIn("repo_add_once", self.postinst)
        self.assertIn("awk", self.postinst)  # preserves unrelated local defaults
        self.assertIn("/etc/default/letsmash", self.postrm)

    def test_purge_removes_the_configuration_and_remove_does_not(self):
        self.assertIn('"${1:-}" = "purge"', self.postrm)
        self.assertIn("/etc/apt/sources.list.d/letsmash.sources", self.postrm)
        self.assertIn("/etc/default/letsmash", self.postrm)
        self.assertIn("repo_add_once", self.postrm)
        self.assertIn("awk", self.postrm)  # preserves unrelated local defaults

    def test_build_stages_the_scripts_and_the_keyring(self):
        build = BUILD.read_text()
        self.assertIn("DEBIAN/$script", build)
        self.assertIn("sed \"s/@ARCH@/$debarch/g\"", build)
        self.assertIn("usr/share/keyrings/letsmash-archive-keyring.gpg", build)


if __name__ == "__main__":
    unittest.main()
