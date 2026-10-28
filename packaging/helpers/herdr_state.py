"""Shared Herdr and git plumbing for the sidebar watchers.

Used by pr-watch-repo and git-status-watch. Both are deployed as siblings of
this module -- `packaging/helpers/` in the repo, the bundle's `bin/` once
installed -- so each of them imports it by putting its own directory on
sys.path instead of naming either layout.

Deliberately a plain top-level module and not a package: build.sh lists
helpers by name and build-common.sh skips directories, so anything under a
`lib/` subdirectory would not reach the installed bundle.
"""

import json
import subprocess
from pathlib import Path


def herdr(*args):
    """Run `herdr ARGS...` and return its JSON `result` member, or None.

    Every caller treats a failed call as "carry the previous reading
    forward", so a failure is data and never an exception.
    """
    out = subprocess.run(["herdr", *args], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)["result"]
    except (json.JSONDecodeError, KeyError):
        return None


def repo_root(path):
    """Absolute toplevel of the repo containing path, or None."""
    r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def load_state(path):
    """What the previous poll recorded, {} when the file is absent or bad."""
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path, data):
    """Persist this poll's readings, creating the state directory if needed."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1))
