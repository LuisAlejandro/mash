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
	for i in $(seq 1 100); do
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

# Stable advisory locks survive abrupt exit without PID-file recovery.
lock_held() {
	python3 - "$lockdir/$1.flock" <<'PY'
import fcntl, sys
with open(sys.argv[1], "a") as handle:
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(0)
    sys.exit(1)
PY
}
lock_held poll || fail "poller must own a kernel lock"

# A second poller for the same server exits and leaves the first in charge.
bash "$poll" || fail "a second poller should exit 0"
kill -0 "$a" 2>/dev/null || fail "the first poller should keep running"

# Reopening a window refreshes even while the hourly poller survives. The
# startup-only process finishes without replacing that poller or sleeping.
bash "$poll" --startup || fail "window startup refresh should finish"
[ "$(grep -h -c ' poll ok' "$state"/*/poll.log | awk '{n += $1} END {print n}')" = 4 ] ||
	fail "window startup should refresh both badges again"
kill -0 "$a" 2>/dev/null || fail "window refresh must preserve the hourly poller"
if lock_held startup; then fail "startup refresh should release its lock"; fi

# TERM stops it at once, removes the lock and leaves no sleeper behind.
kill "$a"
wait "$a" 2>/dev/null || true
if lock_held poll; then fail "lock should be released on TERM"; fi

# A failed startup poll must retry within this test's ten-second deadline,
# rather than entering the hourly delay.
printf '#!/bin/sh\nif [ ! -f "$RETRY_MARK" ]; then touch "$RETRY_MARK"; exit 1; fi\necho recovered\n' >"$tmp/bin/pr-watch-repo"
export RETRY_MARK="$tmp/retry-mark"
bash "$poll" &
r=$!
pids+=("$r")
wait_for 'grep -q recovered "$state/pr-watch-repo/poll.log"' || fail "startup failure should retry"
kill "$r"
wait "$r" 2>/dev/null || true
# wait_for above already bounded the retry to less than ten seconds.

# A lock left by a dead process is taken over.
mkdir -p "$lockdir/poll.lock"
# An unrelated live PID in the legacy directory must not suppress the new owner.
echo $$ >"$lockdir/poll.lock/pid"
bash "$poll" &
b=$!
pids+=("$b")
wait_for 'lock_held poll' || fail "legacy pid directories must not suppress ownership"
kill -KILL "$b"
wait "$b" 2>/dev/null || true
if lock_held poll; then fail "watcher/sleeper must not inherit ownership after SIGKILL"; fi
bash "$poll" &
b=$!
pids+=("$b")
wait_for 'lock_held poll' || fail "abrupt owner exit must allow reacquisition"
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

# Real concurrent contenders, with the winning watcher blocked until killed.
# The descriptor must not leak into that still-running watcher after SIGKILL.
python3 - "$poll" "$tmp" <<'PY'
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

poll, tmp = sys.argv[1:]
for abrupt in (False, True):
    state = Path(tmp) / str(abrupt) / "home/.mash/state"
    state.mkdir(parents=True)
    entered = state / "entered"
    watcher = state / "watcher"
    watcher.write_text('#!/bin/sh\necho $$ >> "$ENTERED"\nexec /bin/sleep 60\n')
    watcher.chmod(0o755)
    env = {**os.environ, "XDG_STATE_HOME": str(state),
           "HERDR_PLUGIN_STATE_DIR": str(state), "ENTERED": str(entered),
           "PR_WATCH_REPO_BIN": str(watcher), "GIT_STATUS_WATCH_BIN": "/missing"}
    contenders = [subprocess.Popen(["bash", poll, "--startup"], env=env) for _ in range(8)]
    watcher_pid = None
    try:
        deadline = time.monotonic() + 10
        while sum(p.poll() is not None for p in contenders) != 7 or not entered.exists():
            assert time.monotonic() < deadline, "contenders did not settle to one owner"
            time.sleep(.02)
        rows = entered.read_text().splitlines()
        assert len(rows) == 1, "duplicate same-mode watcher"
        watcher_pid = int(rows[0])
        owner = next(p for p in contenders if p.poll() is None)
        owner.send_signal(signal.SIGKILL if abrupt else signal.SIGTERM)
        owner.wait(timeout=5)
        with (state / "startup.flock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not abrupt:
            try:
                os.kill(watcher_pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("TERM left the active watcher running")
    finally:
        for p in contenders:
            if p.poll() is None:
                p.kill()
            p.wait(timeout=5)
        if watcher_pid is None and entered.exists():
            watcher_pid = int(entered.read_text().splitlines()[0])
        if watcher_pid:
            try:
                os.killpg(watcher_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY

echo "pr-watch poll: ok"
