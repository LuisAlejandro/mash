#!/usr/bin/env bash
# Refresh pr-watch-repo's PR badges AND git-status-watch's ahead/behind counts
# for the workspace that was just focused. Invoked by Herdr as a
# workspace.focused event hook.
#
# Runs both watchers in the background and exits immediately: a focus event
# must never make switching workspaces feel laggy. pr-watch-repo makes real
# `gh` API calls per open PR (including a GraphQL review-threads query each);
# git-status-watch runs `git fetch` before computing ahead/behind, a real
# network round-trip. Both can run for seconds.
#
# --quiet suppresses the "PR buckets changed" notification pr-watch-repo
# normally fires: a notification for every workspace switch where counts
# happened to differ would be noise, not signal. git-status-watch has no
# notification to suppress. The hourly LaunchAgent runs still notify (for
# pr-watch-repo) normally; only this on-focus trigger is silenced.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr_watch_repo="${PR_WATCH_REPO_BIN:-$(command -v pr-watch-repo || true)}"
git_status_watch="${GIT_STATUS_WATCH_BIN:-$(command -v git-status-watch || true)}"
state="${XDG_STATE_HOME:-}"
case "$state" in
	/*/.mash/*) ;;
	*) exit 1 ;;
esac

json="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$json" ] || exit 0

# workspace.focused's payload is a flat data.workspace_id (not nested under a
# "workspace" object the way tab.created nests under "tab") -- confirmed
# against fullerzz.sesh's own handler for this same event.
workspace_id="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin).get("data") or {}
except Exception:
    data = {}
print(data.get("workspace_id") or "")
' 2>/dev/null || true)"

[ -n "$workspace_id" ] || exit 0

if [ -x "$pr_watch_repo" ]; then
	log="$state/pr-watch-repo/focus-hook.log"
	mkdir -p "$(dirname "$log")"
	nohup "$pr_watch_repo" --quiet --workspace "$workspace_id" \
		>>"$log" 2>&1 &
	disown
fi

if [ -x "$git_status_watch" ]; then
	log="$state/git-status-watch/focus-hook.log"
	mkdir -p "$(dirname "$log")"
	nohup "$git_status_watch" --workspace "$workspace_id" \
		>>"$log" 2>&1 &
	disown
fi

exit 0
