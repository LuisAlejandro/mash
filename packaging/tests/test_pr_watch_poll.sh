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

# Reopening a window refreshes even while the hourly poller survives. The
# startup-only process finishes without replacing that poller or sleeping.
bash "$poll" --startup || fail "window startup refresh should finish"
[ "$(grep -h -c ' poll ok' "$state"/*/poll.log | awk '{n += $1} END {print n}')" = 4 ] ||
	fail "window startup should refresh both badges again"
kill -0 "$a" 2>/dev/null || fail "window refresh must preserve the hourly poller"
[ ! -d "$lockdir/startup.lock" ] || fail "startup refresh should release its lock"

# TERM stops it at once, removes the lock and leaves no sleeper behind.
kill "$a"
wait "$a" 2>/dev/null || true
wait_for '[ ! -d "$lockdir/poll.lock" ]' || fail "lock should be removed on TERM"

# A failed startup poll must retry before the hourly sleep. Stub sleep so
# retries are fast without changing production timing.
mkdir -p "$tmp/sleep-bin"
printf '#!/bin/sh\necho "$1" >> "$SLEEP_LOG"\nexec /bin/sleep 0.1\n' >"$tmp/sleep-bin/sleep"
chmod +x "$tmp/sleep-bin/sleep"
printf '#!/bin/sh\nif [ ! -f "$RETRY_MARK" ]; then touch "$RETRY_MARK"; exit 1; fi\necho recovered\n' >"$tmp/bin/pr-watch-repo"
export RETRY_MARK="$tmp/retry-mark" SLEEP_LOG="$tmp/sleeps"
PATH="$tmp/sleep-bin:$PATH" bash "$poll" &
r=$!
pids+=("$r")
wait_for 'grep -q recovered "$state/pr-watch-repo/poll.log"' || fail "startup failure should retry"
kill "$r"
wait "$r" 2>/dev/null || true
[ "$(head -1 "$SLEEP_LOG")" -lt 3600 ] || fail "startup retry must not wait an hour"

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

# A successful but empty pane listing is not startup readiness. Both real
# watchers must request a retry instead of recording an empty successful poll.
printf '#!/bin/sh\nprintf '\''{"result":{"panes":[]}}\\n'\''\n' >"$tmp/bin/herdr"
chmod +x "$tmp/bin/herdr"
for helper in pr-watch-repo git-status-watch; do
	if PATH="$tmp/bin:$PATH" python3 "$here/../helpers/$helper"; then
		fail "$helper should retry when startup panes are not restored yet"
	fi
done

echo "pr-watch poll: ok"
