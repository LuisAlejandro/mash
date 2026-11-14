"""The seeded fork chords and the fork-from-message manifest must agree.

A merge commit rewrote this plugin's manifest by hand: the `picker` pane
entrypoint disappeared, all three actions were repointed at `picker.py`, and
their ids changed to `fork-tab`/`fork-split`. `picker.py` only renders a list
handed to it through HERDR_FORK_REQUEST, which the orchestrator
(`fork_from_message.py`) sets when it opens that pane, so the rewritten entries
could not work even before Herdr answered the chord with "Action rejected:
plugin action not found". Herdr only resolves `plugin.action` at press time, so
nothing failed at startup.

The general half reads both seeded configs and the bundled manifests together.
The fork half pins the shape the orchestrator needs: actions run
`fork_from_message.py`, and the pane it opens by name exists.

Plugins fetched at build time (annotate, ray.plugin-manager) have no manifest
in this repository; those bindings are left alone.

Run with: python3 packaging/tests/test_plugin_action_bindings.py
"""

import re
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
                self.assertIn(("fork-from-message", "fork"), bound)
                self.assertIn(("fork-from-message", "fork-pane"), bound)
                self.assertIn(("fork-from-message", "fork-workspace"), bound)
                self.assertTrue(actions["fork-from-message"])

    def test_the_picker_pane_the_orchestrator_opens_exists(self) -> None:
        manifest = tomllib.loads(
            (PLUGINS / "fork-from-message" / "herdr-plugin.toml").read_text(encoding="utf-8")
        )
        panes = {pane["id"]: pane for pane in manifest.get("panes") or []}
        orchestrator = (PLUGINS / "fork-from-message" / "scripts" / "fork_from_message.py").read_text(
            encoding="utf-8"
        )
        entrypoints = set(re.findall(r'"--entrypoint",\s*"([^"]+)"', orchestrator))
        self.assertTrue(entrypoints, "fork_from_message.py opens no plugin pane by name")
        for entrypoint in entrypoints:
            with self.subTest(entrypoint=entrypoint):
                self.assertIn(entrypoint, panes, "the picker pane entrypoint is missing")
        for action in manifest.get("actions") or []:
            with self.subTest(action=action["id"]):
                self.assertIn(
                    "fork_from_message.py",
                    " ".join(action["command"]),
                    "an action entrypoint bypasses the orchestrator",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
