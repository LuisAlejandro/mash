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


if __name__ == "__main__":
    unittest.main()
