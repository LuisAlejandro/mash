#!/usr/bin/env bash
# Enrich a bare new Herdr tab into the same layout as cmd+t: fresh left, pi
# right, split at the same ratio. Invoked by Herdr as a tab.created event hook.
#
# Herdr's "+" button runs the built-in new_tab action and exposes no setting to
# redirect it, so reacting to the tab it creates is the only lever. That means
# this hook sees *every* tab creation, including tabs the other launcher
# scripts and plugin pane entries create. The filters below exist to leave
# those alone.
#
# This hook never calls `herdr tab create`: that would fire tab.created again
# and recurse. It only splits the tab that already exists.
#
# The hook runs asynchronously -- `herdr tab create` returns before this
# finishes -- so any decision must come from data captured in the event
# payload, never from the tab's state at some later moment.
set -eu

herdr="${HERDR_BIN_PATH:-herdr}"
# FRESH_RATIO is read by bin/herdr-dev-tab-fill (inherited through the
# environment), not here.
dev_tab_fill="${DEV_TAB_FILL_BIN:-$(command -v herdr-dev-tab-fill || true)}"

json="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$json" ] || exit 0

# tab_id, label and pane_count all live in this one payload, so read them in a
# single interpreter start rather than three.
fields="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    tab = (json.load(sys.stdin).get("data") or {}).get("tab") or {}
except Exception:
    tab = {}
# 0x1f is not IFS whitespace, so an empty label keeps its own field instead of
# collapsing into the next one.
print("\x1f".join("" if tab.get(k) is None else str(tab.get(k))
                  for k in ("tab_id", "label", "pane_count")))
' 2>/dev/null || true)"
IFS=$'\x1f' read -r tab_id label pane_count <<<"$fields" || true

[ -n "$tab_id" ] || exit 0

# A "+" press yields exactly one pane. Anything already split belongs to a
# script that owns its own layout.
[ "$pane_count" = "1" ] || exit 0

# The other launcher scripts pass this prefix as --label at creation, so it is
# present in this payload. Checking the payload rather than re-reading the tab
# is race-free: those scripts rename the label away once their setup is done.
case "$label" in
herdr-tab-launcher-*) exit 0 ;;
esac

# A workspace's first tab is numbered "1" -- that is a brand-new workspace, a
# worktree, or a restored session, not a "+" press inside an existing
# workspace. A "+" press in a workspace that already has tabs always lands on
# 2 or higher.
[ "$label" != "1" ] || exit 0

# Locate the tab's root pane.
pane="$("$herdr" pane list 2>/dev/null | python3 -c '
import json, sys
tab = sys.argv[1]
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    sys.exit(0)
for p in panes:
    if p.get("tab_id") == tab:
        print(p["pane_id"])
        break
' "$tab_id" 2>/dev/null || true)"
[ -n "$pane" ] || exit 0

# Only enrich a pane that has settled into a bare shell. A tab opened by a
# plugin pane entry (reviewr) is already running that program, and splitting it
# would fight the plugin's own layout.
#
# The check has to poll. A login shell runs its rc files on startup, spawning
# transient processes (git, atuin, ...), so a single sample taken right after
# tab creation can catch one of those instead of the shell and wrongly conclude
# this is not a bare tab. That race is why the feature was intermittent: the
# same chord sometimes enriched and sometimes did not. Wait for the foreground
# process to repeat, which means startup has stopped churning.
fg=""
prev="__unset__"
for _ in $(seq 1 40); do
	now="$("$herdr" pane process-info --pane "$pane" 2>/dev/null | python3 -c '
import json, sys
try:
    info = json.load(sys.stdin)["result"]["process_info"]
except Exception:
    sys.exit(0)
procs = info.get("foreground_processes") or []
if procs:
    print(procs[0].get("name") or "")
' 2>/dev/null || true)"
	if [ -n "$now" ] && [ "$now" = "$prev" ]; then
		fg="$now"
		break
	fi
	prev="$now"
	sleep 0.2
done

[ -n "$fg" ] || exit 0

# Compare against the login shell as well as the common names, so a shell
# outside this list does not silently disable enrichment.
case "$fg" in
zsh | bash | sh | dash | ksh | fish | "${SHELL##*/}") ;;
*) exit 0 ;;
esac

# Re-read the pane count: this hook runs concurrently with the launcher scripts,
# so a tab that was single-pane at event time may have been split since.
panes_now="$("$herdr" tab get "$tab_id" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["result"]["tab"].get("pane_count") or "")
except Exception:
    print("")
' 2>/dev/null || true)"
[ "$panes_now" = "1" ] || exit 0

# Match cmd+t exactly by delegating to the same script the cmd+t launcher uses.
# The two used to write this layout out separately and drifted: the hook kept
# launching a bare `fresh` (no file explorer, right-click going to Herdr
# instead of Fresh, no resume command so the pane did not survive a server
# restart) and an untracked `pi` (no sidebar status, not addressable by
# `herdr agent prompt`). bin/herdr-dev-tab-fill splits off the right pane,
# runs fresh on the left through the herdr-fresh-pane wrapper, starts a
# tracked pi agent on the right, and moves focus to pi once it is ready -- so
# the "+" button lands the caret in pi exactly like cmd+t does.
[ -x "$dev_tab_fill" ] || exit 0
"$dev_tab_fill" "$pane"
