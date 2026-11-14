"""Every seeded plugin chord names an action its bundled plugin registers.

Herdr only resolves `plugin.action` at press time, so a binding for an action
the manifest does not declare fails silently at startup and answers the chord
with "Action rejected: plugin action not found". That is how the fork chords
broke when a merge rewrote the old fork-from-message manifest by hand.

The fork chords are no longer plugin actions: herdr-fork-pi starts Pi in the
destination and Pi's own /fork finishes there. The last test pins that wiring,
so the chords cannot drift back to a plugin that no longer ships.

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
FORK_CHORDS = {
    "Fork agent from message": "tab",
    "Fork agent beside current pane": "pane",
    "Fork agent into new workspace": "workspace",
}


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


def commands(config: str) -> list[dict]:
    data = tomllib.loads((DEFAULTS / config).read_text(encoding="utf-8"))
    return data.get("keys", {}).get("command", [])


class PluginActionBindingTest(unittest.TestCase):
    def test_every_seeded_binding_names_a_bundled_action(self) -> None:
        actions = bundled_actions()
        for config in CONFIGS:
            for command in commands(config):
                if command.get("type") != "plugin_action":
                    continue
                plugin, _, action = str(command.get("command", "")).partition(".")
                if plugin not in actions:
                    continue
                with self.subTest(config=config, plugin=plugin, action=action):
                    self.assertIn(
                        action,
                        actions[plugin],
                        f"{config} binds {plugin}.{action}, which {plugin} does not register",
                    )

    def test_the_fork_chords_run_the_launcher(self) -> None:
        self.assertTrue((PACKAGING / "helpers" / "herdr-fork-pi").is_file())
        self.assertTrue((PACKAGING / "defaults" / "pi" / "extensions" / "fork-from-message.ts").is_file())
        for config in CONFIGS:
            by_description = {c.get("description"): c for c in commands(config)}
            for description, destination in FORK_CHORDS.items():
                with self.subTest(config=config, chord=description):
                    command = by_description.get(description)
                    self.assertIsNotNone(command, f"{config} lost the {description!r} chord")
                    self.assertEqual(command.get("type"), "shell")
                    self.assertTrue(
                        str(command.get("command", "")).endswith(f"herdr-fork-pi {destination}"),
                        command.get("command"),
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
