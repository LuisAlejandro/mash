"""The macOS updater must ship as one signed unit, without entering Linux."""

import pathlib
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MacOSUpdatePackageTest(unittest.TestCase):
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
