#!/usr/bin/env bash
# packaging/plugins/pr-watch-focus/poll.sh: the hourly watcher poll that
# replaces the personal setup's two LaunchAgents. Runs with stub watchers in a
# throwaway state dir; never starts Herdr and never touches a real ~/.mash.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
poll="$here/../plugins/pr-watch-focus/poll.sh"
tmp="$(mktemp -d)"
pids=()
cleanup() {
	for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
	rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

state="$tmp/home/.mash/local/state"
lockdir="$state/herdr/plugins/pr-watch-focus"
mkdir -p "$state" "$tmp/bin"
for n in pr-watch-repo git-status-watch; do
	printf '#!/bin/sh\necho "%s ran"\n' "$n" >"$tmp/bin/$n"
	chmod +x "$tmp/bin/$n"
done
export XDG_STATE_HOME="$state" HERDR_PLUGIN_STATE_DIR="$lockdir"
export PR_WATCH_REPO_BIN="$tmp/bin/pr-watch-repo" GIT_STATUS_WATCH_BIN="$tmp/bin/git-status-watch"

wait_for() {
	local i
	for i in $(seq 1 50); do
		eval "$1" && return 0
		sleep 0.1
	done
	return 1
}

# Both watchers run as soon as the poller starts, like RunAtLoad did.
bash "$poll" &
a=$!
pids+=("$a")
wait_for '[ "$(cat "$state"/*/poll.log 2>/dev/null | grep -c " poll ok")" = 2 ]' ||
	fail "both watchers should run on start"

# A second poller for the same server exits and leaves the first in charge.
bash "$poll" || fail "a second poller should exit 0"
kill -0 "$a" 2>/dev/null || fail "the first poller should keep running"

# TERM stops it at once, removes the lock and leaves no sleeper behind.
kill "$a"
wait "$a" 2>/dev/null || true
wait_for '[ ! -d "$lockdir/poll.lock" ]' || fail "lock should be removed on TERM"

# A lock left by a dead process is taken over.
mkdir -p "$lockdir/poll.lock"
echo 999999 >"$lockdir/poll.lock/pid"
bash "$poll" &
b=$!
pids+=("$b")
wait_for '[ "$(cat "$lockdir/poll.lock/pid" 2>/dev/null)" = "$b" ]' ||
	fail "a stale lock should be taken over"
kill "$b"
wait "$b" 2>/dev/null || true

# It never runs against state outside ~/.mash, so it cannot write to the
# owner's own watcher state.
if XDG_STATE_HOME="$tmp/home/.local/state" bash "$poll"; then
	fail "should refuse a state dir outside ~/.mash"
fi

echo "pr-watch poll: ok"
