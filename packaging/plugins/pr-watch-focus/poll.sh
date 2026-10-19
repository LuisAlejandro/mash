#!/usr/bin/env bash
# Hourly PR-badge and ahead/behind poll, for as long as Mash's Herdr runs.
#
# The personal setup ran pr-watch-repo and git-status-watch from two hourly
# LaunchAgents. Mash ships both watchers but nothing ran them on a schedule:
# only focus.sh, on workspace.focused, so a workspace that was never focused
# again never got its badges refreshed, and Mash's own Herdr config already
# described them as "polled hourly by the app".
#
# A Herdr startup process rather than a LaunchAgent, on purpose:
#   - it lives exactly as long as Mash's Herdr server, and needs no plist in
#     ~/Library and no launchctl state to clean up when Mash is removed;
#   - it inherits the server's environment -- Mash's PATH, HERDR_SOCKET_PATH
#     and XDG_STATE_HOME -- so the watchers can only ever see Mash's Herdr,
#     never the owner's own.
#
# One poller per server: a pid lock in the plugin state dir, the same pattern
# cache-hit's watch.sh uses. A second startup (a plugin reload, a server
# restart that left a stale lock) finds a live owner and exits, or takes over
# a dead one.
set -u

state="${XDG_STATE_HOME:-}"
case "$state" in
/*/.mash/*) ;;
*) exit 1 ;;
esac

interval="${MASH_WATCH_INTERVAL_SECONDS:-3600}"
case "$interval" in
'' | *[!0-9]*) interval=3600 ;;
esac
[ "$interval" -ge 60 ] || interval=60

pr_watch_repo="${PR_WATCH_REPO_BIN:-$(command -v pr-watch-repo || true)}"
git_status_watch="${GIT_STATUS_WATCH_BIN:-$(command -v git-status-watch || true)}"

lock_root="${HERDR_PLUGIN_STATE_DIR:-$state/herdr/plugins/pr-watch-focus}"
lock="$lock_root/poll.lock"
mkdir -p "$lock_root"
if ! mkdir "$lock" 2>/dev/null; then
	owner="$(cat "$lock/pid" 2>/dev/null || true)"
	case "$owner" in
	'' | *[!0-9]*) ;;
	*) kill -0 "$owner" 2>/dev/null && exit 0 ;;
	esac
	rm -rf "$lock" && mkdir "$lock" 2>/dev/null || exit 0
fi
printf '%s\n' "$$" >"$lock/pid"
sleeper=""
trap 'rm -rf "$lock"; [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null' EXIT
trap 'exit 0' HUP INT TERM

log() {
	mkdir -p "$state/$1"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >>"$state/$1/poll.log"
}

run_watcher() {
	local name="$1" bin="$2"
	[ -x "$bin" ] || return 0
	if "$bin" >>"$state/$name/poll.log" 2>&1; then
		log "$name" "poll ok"
	else
		log "$name" "poll failed ($?)"
	fi
}

# The first pass is the LaunchAgent's RunAtLoad: badges are filled in as soon
# as Mash opens rather than an hour later. The sleep runs in the background and
# is waited on, so a TERM from a stopping server ends the poller at once
# instead of after the current sleep step.
while :; do
	mkdir -p "$state/pr-watch-repo" "$state/git-status-watch"
	run_watcher pr-watch-repo "$pr_watch_repo"
	run_watcher git-status-watch "$git_status_watch"
	sleep "$interval" &
	sleeper=$!
	wait "$sleeper" || exit 0
	sleeper=""
done
