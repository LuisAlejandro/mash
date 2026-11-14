"""Every seeded keybinding must name a plugin action that exists.

The failure this pins: fork-from-message rewrote its manifest from
`fork`/`fork-pane`/`fork-workspace` to `fork-tab`/`fork-split`/`fork-workspace`
for the picker flow, and the seeded chords kept the old ids. Herdr only
resolves `plugin.action` at press time, so nothing failed at startup -- the
chord answered "Action rejected: plugin action not found" instead of opening
the picker.

Plugins fetched at build time (annotate, ray.plugin-manager) have no manifest
in this repository; those bindings are left alone.

Run with: python3 packaging/tests/test_plugin_action_bindings.py
"""

import tomllib
import unittest
from pathlib import Path

PACKAGING = Path(__file__).resolve().parents[1]
DEFAULTS = PACKAGING / "defaults" / "herdr"
PLUGINS = PACKAGING / "plugins"
CONFIGS = ("config.toml", "config.linux.toml")


def bundled_actions() -> dict[str, set[str]]:
    """Map each bundled plugin id to the action and pane ids it registers."""
    found: dict[str, set[str]] = {}
    manifests = sorted(PLUGINS.glob("*/herdr-plugin.toml")) + sorted(
        PLUGINS.glob("*/lite/herdr-plugin.toml")
    )
    for manifest in manifests:
        data = tomllib.loads(manifest.read_text(encoding="utf-8"))
        found[data["id"]] = {
            entry["id"]
            for entry in (data.get("actions") or []) + (data.get("panes") or [])
        }
    return found


def plugin_bindings(config: str) -> list[tuple[str, str]]:
    """Every `plugin_action` entry as (plugin id, action id)."""
    data = tomllib.loads((DEFAULTS / config).read_text(encoding="utf-8"))
    bound = []
    for command in data.get("keys", {}).get("command", []):
        if command.get("type") != "plugin_action":
            continue
        plugin, _, action = str(command.get("command", "")).partition(".")
        bound.append((plugin, action))
    return bound


class PluginActionBindingTest(unittest.TestCase):
    def test_every_seeded_binding_names_a_bundled_action(self) -> None:
        actions = bundled_actions()
        for config in CONFIGS:
            for plugin, action in plugin_bindings(config):
                if plugin not in actions:
                    continue
                with self.subTest(config=config, plugin=plugin, action=action):
                    self.assertIn(plugin, actions, f"{config}: unknown plugin {plugin}")
                    self.assertIn(
                        action,
                        actions[plugin],
                        f"{config} binds {plugin}.{action}, "
                        f"which {plugin} does not register",
                    )

    def test_the_fork_chords_reach_the_picker_actions(self) -> None:
        actions = bundled_actions()
        for config in CONFIGS:
            bound = plugin_bindings(config)
            with self.subTest(config=config):
                self.assertIn(("fork-from-message", "fork-tab"), bound)
                self.assertIn(("fork-from-message", "fork-split"), bound)
                self.assertIn(("fork-from-message", "fork-workspace"), bound)
                self.assertTrue(actions["fork-from-message"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
