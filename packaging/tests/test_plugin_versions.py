"""Every bundled plugin's version must change when its contents change.

Herdr keeps a registry copy of each plugin's manifest, and Mash only relinks a
bundled plugin when the recorded version differs from the bundle's. A plugin
edited without a version bump therefore never reaches users who already have
it registered, which is how fork-from-message and image-popup went stale.

packaging/plugins/versions.lock.json records, per plugin, the version and a
digest of its tracked and unignored working-tree files. This test fails when a
digest changes while its version does not.

After a deliberate change, bump the plugin's herdr-plugin.toml version and run:

    python3 packaging/tests/test_plugin_versions.py --update
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLUGINS = ROOT / "packaging" / "plugins"
LOCK = PLUGINS / "versions.lock.json"


def plugin_ids():
    """Map each bundled plugin directory to its manifest id and version."""
    found = {}
    for manifest in sorted(PLUGINS.glob("*/herdr-plugin.toml")) + sorted(
        PLUGINS.glob("*/lite/herdr-plugin.toml")
    ):
        text = manifest.read_text(encoding="utf-8")
        pid = re.search(r'^id\s*=\s*"([^"]+)"', text, re.M)
        version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
        if not pid or not version:
            raise SystemExit(f"{manifest}: id and version are required")
        found[pid.group(1)] = {
            "dir": manifest.parent,
            "version": version.group(1),
        }
    return found


def tracked_files(directory):
    """Tracked plus unignored working-tree files, so uncommitted edits count.

    Ignored build output (target/, bin/, __pycache__) is excluded by git itself.
    """
    rel = directory.relative_to(ROOT)
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", str(rel)],
        capture_output=True, check=True,
    ).stdout.decode("utf-8")
    return sorted(
        path for path in out.split("\0") if path and (ROOT / path).is_file()
    )


def digest(directory):
    h = hashlib.sha256()
    for path in tracked_files(directory):
        h.update(path.encode("utf-8") + b"\0")
        h.update((ROOT / path).read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def current_state():
    return {
        pid: {"version": info["version"], "digest": digest(info["dir"])}
        for pid, info in plugin_ids().items()
    }


def write_lock():
    LOCK.write_text(
        json.dumps(current_state(), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


class TestPluginVersions(unittest.TestCase):
    def test_action_contexts_are_supported_by_the_pinned_herdr(self):
        # Herdr 0.9.5 rejects an unknown enum during plugin linking, late in
        # the app build. Agent-only actions still use the pane context and
        # validate the selected agent themselves.
        supported = {"global", "workspace", "tab", "pane", "selection"}
        for info in plugin_ids().values():
            manifest = info["dir"] / "herdr-plugin.toml"
            data = tomllib.loads(manifest.read_text(encoding="utf-8"))
            for action in data.get("actions", []):
                with self.subTest(manifest=str(manifest), action=action["id"]):
                    self.assertLessEqual(set(action.get("contexts", [])), supported)

    def test_changed_plugins_bump_their_version(self):
        recorded = json.loads(LOCK.read_text(encoding="utf-8"))
        problems = []
        for pid, now in current_state().items():
            before = recorded.get(pid)
            if before is None:
                problems.append(f"{pid}: not in versions.lock.json")
            elif before["digest"] != now["digest"] and before["version"] == now["version"]:
                problems.append(
                    f"{pid}: contents changed but version stays {now['version']}"
                )
        for pid in recorded:
            if pid not in plugin_ids():
                problems.append(f"{pid}: in versions.lock.json but no longer bundled")
        self.assertFalse(
            problems,
            "Bump the version in herdr-plugin.toml, then run "
            "python3 packaging/tests/test_plugin_versions.py --update:\n  "
            + "\n  ".join(problems),
        )


if __name__ == "__main__":
    if "--update" in sys.argv:
        write_lock()
        print(f"wrote {LOCK.relative_to(ROOT)}")
    else:
        unittest.main()
