"""Snapshot Herdr tabs so an accidentally closed one can be reopened.

Herdr 0.9.3 has no reopen-closed-tab action, and closing a tab kills its PTYs,
so nothing can be recovered after the fact: the state has to be written while
the tab still exists. Its `tab.closed` event cannot supply it either -- by the
time that hook runs the panes are gone -- so the reopen-tab plugin refreshes a
cache of every tab on the events that can change one (creation, focus, rename,
pane split, pane close) and the close hook moves the vanished entry onto an undo
stack. `herdr-tabs capture|closed|reopen` is the entry point; see the plugin's
herdr-plugin.toml for the event wiring.

Reopening rebuilds the tab from that snapshot: its workspace, a cwd per pane,
the split geometry, Fresh and pi panes restarted in their own directories, and
pi on the session file it was in. What a rebuilt tab cannot have is the old
PTY: scrollback, unsaved editor buffers, and any program this module does not
know how to restart are gone with it. Only Fresh and pi are restarted; every
other pane comes back as a shell in its directory.

State lives under $XDG_STATE_HOME/mash/closed-tabs, beside mash-pane-resume's
ledger and for the same reason: it is per-machine working state, not config.
"""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

# How many closed tabs stay reopenable, newest last. A tab's PTY is already
# gone, so this is only the memory of its layout -- ten is plenty to cover the
# "I closed the wrong one" case without keeping a day's worth of dead tabs.
STACK_LIMIT = 10

# The label every Mash launcher stamps on a tab it creates, so the dev-tab
# plugin's tab.created hook leaves the tab alone. A reopened tab needs the same
# mark: the hook would otherwise turn a restored one-pane tab into a dev tab.
LAUNCH_LABEL = "herdr-tab-launcher-reopen"

HERDR = os.environ.get("HERDR_BIN_PATH") or "herdr"


def herdr(*args):
    """Run `herdr ARGS...` and return its JSON `result` member, or None.

    Every caller treats a failed call as data, never as an exception: a hook
    that raises is a hook that reports a plugin error on every tab focus.
    """
    try:
        done = subprocess.run([HERDR, *args], capture_output=True, text=True)
    except OSError:
        return None
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout).get("result")
    except (ValueError, AttributeError):
        return None


def dig(node, key):
    """First scalar value for KEY anywhere in a Herdr reply, or None.

    Herdr's replies nest their payload (a created tab is {tab, root_pane}), and
    the field a caller wants sits at a depth that has changed between versions.
    herdr-json walks the document for the same reason; this is that walk.
    """
    if isinstance(node, dict):
        for name, value in node.items():
            if name == key and not isinstance(value, (dict, list)):
                return value
            found = dig(value, key)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = dig(value, key)
            if found is not None:
                return found
    return None


def pane_ids(tab_id):
    panes = (herdr("pane", "list") or {}).get("panes") or []
    return {p.get("pane_id") for p in panes if p.get("tab_id") == tab_id}


def bundled(program):
    """Absolute path to a program Mash bundles, or "" when it is missing."""
    mash_bin = Path(__file__).resolve().parent / "mash-bin"
    try:
        done = subprocess.run(
            [str(mash_bin), "--bundled", program], capture_output=True, text=True
        )
    except OSError:
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


def state_dir():
    """$XDG_STATE_HOME/mash/closed-tabs, or None when Mash set no state dir."""
    root = os.environ.get("XDG_STATE_HOME")
    return Path(root) / "mash" / "closed-tabs" if root else None


def load(path, fallback):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return fallback


def store(path, data):
    """Write through a temp file: a hook and the chord can run concurrently.

    A half-written cache would cost the next reopen its snapshot, and this is
    the only copy of a closed tab's layout.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(data))
    temp.replace(path)


def area(rect):
    rect = rect or {}
    return int(rect.get("width") or 0) * int(rect.get("height") or 0)


def arrange(tab_panes):
    """Order a tab's panes left-to-right then top-to-bottom, plus its splits.

    Geometry is what makes a rebuilt tab look like the closed one, so it costs
    one `pane layout` call -- but only for tabs that have more than one pane,
    which is what nearly every tab has zero or one of.
    """
    if len(tab_panes) == 1:
        return tab_panes, []
    layout = (herdr("pane", "layout", "--pane", tab_panes[0].get("pane_id")) or {}).get(
        "layout"
    ) or {}
    rects = {p.get("pane_id"): p.get("rect") or {} for p in layout.get("panes") or []}

    def position(pane):
        rect = rects.get(pane.get("pane_id"))
        if rect is None:  # a pane the layout no longer reports: keep input order
            return (10**6, 10**6)
        return (int(rect.get("x") or 0), int(rect.get("y") or 0))

    # Largest split first, so a rebuilt nested layout splits the same parent
    # before it splits the child.
    splits = [
        {"direction": s.get("direction") or "right", "ratio": s.get("ratio") or 0.5}
        for s in sorted(layout.get("splits") or [], key=lambda s: -area(s.get("rect")))
    ]
    return sorted(tab_panes, key=position), splits


def snapshot():
    """Every tab in the session, with the panes and programs inside it."""
    tabs = herdr("tab", "list") or {}
    panes = herdr("pane", "list") or {}
    by_tab = {}
    for pane in panes.get("panes") or []:
        by_tab.setdefault(pane.get("tab_id"), []).append(pane)

    shots = []
    for tab in tabs.get("tabs") or []:
        tab_panes = by_tab.get(tab.get("tab_id")) or []
        if not tab_panes:  # a tab already being torn down
            continue
        ordered, splits = arrange(tab_panes)
        shots.append(
            {
                "tab_id": tab.get("tab_id"),
                "workspace_id": tab.get("workspace_id"),
                "label": tab.get("label") or "",
                "splits": splits,
                "panes": [
                    {
                        "cwd": pane.get("cwd") or pane.get("foreground_cwd") or "",
                        "agent": pane.get("agent") or "",
                        "session": (pane.get("agent_session") or {}).get("value") or "",
                    }
                    for pane in ordered
                ],
            }
        )
    return {"tabs": shots}


def capture():
    """Refresh the cache from the live session, never dropping a closed tab.

    Closing a tab emits pane.closed before tab.closed, so a capture triggered
    by the pane event runs while the tab is already gone from `pane list` and
    would otherwise erase the very snapshot the close hook is about to bury.
    Entries for tabs the session no longer reports are therefore kept until
    remember_closed prunes them -- which happens on the next close.
    """
    base = state_dir()
    if base is None:
        return 0
    cache_path = base / "cache.json"
    cached = load(cache_path, {"tabs": []}).get("tabs") or []
    live = snapshot()["tabs"]
    fresh = {tab.get("tab_id") for tab in live}
    kept = [tab for tab in cached if tab.get("tab_id") not in fresh]
    store(cache_path, {"tabs": live + kept})
    return 0


def remember_closed():
    """Move every cached tab that no longer exists onto the undo stack.

    Comparing the cache against the live tab list rather than trusting the
    event payload recovers every close path at once -- the chord, the tab bar's
    close button, and the last pane exiting -- and needs nothing from Herdr's
    event shape beyond the tab ids it already reports.
    """
    base = state_dir()
    if base is None:
        return 0
    cache_path, stack_path = base / "cache.json", base / "stack.json"
    cached = load(cache_path, {"tabs": []}).get("tabs") or []
    live = herdr("tab", "list") or {}
    alive = {tab.get("tab_id") for tab in live.get("tabs") or []}
    vanished = [tab for tab in cached if tab.get("tab_id") not in alive]
    if not vanished:
        return 0

    stack = load(stack_path, [])
    # Herdr never reuses a closed tab id, so an id already on the stack has
    # been remembered: a second push is a stale cache write racing this hook,
    # not a second close.
    known = {tab.get("tab_id") for tab in stack}
    stack.extend(tab for tab in vanished if tab.get("tab_id") not in known)
    store(stack_path, stack[-STACK_LIMIT:])
    store(cache_path, {"tabs": [tab for tab in cached if tab.get("tab_id") in alive]})
    return 0


def notify(title, body=""):
    args = ["notification", "show", title]
    if body:
        args += ["--body", body]
    herdr(*args)


def restart(pane_id, pane, pi):
    """Start the program a pane was running, when this module knows how.

    Untracked `pane run` rather than `herdr agent start`: Herdr's own
    pane.agent_detected fires for a tracked agent kind anyway, and an untracked
    launch is the one path that can carry pi's `--session` argument without
    growing herdr-agent-start a second calling convention.
    """
    agent = pane.get("agent") or ""
    if agent == "pi" and pi:
        command = shlex.quote(pi)
        session = pane.get("session") or ""
        # A session file can be deleted between the close and the reopen; pi
        # exits 1 on a missing one, which would leave the pane a dead shell.
        if session and Path(session).is_file():
            command += " --session " + shlex.quote(session)
        herdr("pane", "run", pane_id, command)
    elif agent == "fresh":
        # herdr-fresh-pane is the Fresh launcher Mash ships: it routes the
        # right-click to Fresh and reports the pane's resume command, so a
        # rebuilt pane behaves like a launched one.
        herdr("pane", "run", pane_id, "herdr-fresh-pane .")
    # Anything else comes back as a shell in its own directory: the process is
    # gone and this module has no command to start it again.


def reopen():
    base = state_dir()
    if base is None:
        return 0
    stack_path = base / "stack.json"
    stack = load(stack_path, [])
    if not stack:
        notify("No closed tab to reopen")
        return 0

    tab = stack[-1]
    pans = tab.get("panes") or []
    workspaces = herdr("workspace", "list") or {}
    known = {w.get("workspace_id") for w in workspaces.get("workspaces") or []}

    args = ["tab", "create", "--label", LAUNCH_LABEL, "--focus"]
    root_cwd = pans[0].get("cwd") if pans else ""
    if root_cwd:
        args += ["--cwd", root_cwd]
    if tab.get("workspace_id") in known:
        args += ["--workspace", tab["workspace_id"]]
    created = herdr(*args) or {}
    root = dig(created, "pane_id")
    tab_id = dig(created, "tab_id")
    if not root:
        # The tab stays on the stack: a failed create is usually a Herdr server
        # that is restarting, and losing the snapshot for it would be worse
        # than a no-op.
        notify("Could not reopen tab", tab.get("label") or root_cwd)
        return 1

    # Pop only once the new tab exists, so a failure above is retryable.
    store(stack_path, stack[:-1])

    splits = tab.get("splits") or []
    anchors = [root]
    for index, pane in enumerate(pans[1:], start=1):
        split = splits[min(index - 1, len(splits) - 1)] if splits else {}
        split_args = [
            "pane",
            "split",
            anchors[-1],
            "--direction",
            split.get("direction") or "right",
            "--no-focus",
        ]
        ratio = split.get("ratio")
        if isinstance(ratio, (int, float)) and 0 < ratio < 1:
            split_args += ["--ratio", f"{ratio:g}"]
        if pane.get("cwd"):
            split_args += ["--cwd", pane["cwd"]]
        # Which pane the split created is read from the tab's pane list rather
        # than from the reply: Herdr's split reply is not a documented shape,
        # while the set difference always names exactly the new pane.
        before = pane_ids(tab_id) if tab_id else set()
        reply = herdr(*split_args) or {}
        new_pane = dig(reply, "pane_id")
        if tab_id:
            added = pane_ids(tab_id) - before
            if len(added) == 1:
                new_pane = added.pop()
        if not new_pane:
            # Half a layout in a tab the user can still use beats no tab.
            break
        anchors.append(new_pane)

    pi = bundled("pi")
    for pane_id, pane in zip(anchors, pans):
        restart(pane_id, pane, pi)

    if tab_id:
        # Clear the launcher label so Herdr resumes auto-naming the tab from
        # its focused pane, exactly as every other launcher leaves it.
        herdr("tab", "rename", tab_id, "")

    notify("Tab reopened", tab.get("label") or "")
    return 0


ACTIONS = {"capture": capture, "closed": remember_closed, "reopen": reopen}


def main(argv):
    if len(argv) != 2 or argv[1] not in ACTIONS:
        raise SystemExit(f"usage: {argv[0]} capture|closed|reopen")
    return ACTIONS[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
