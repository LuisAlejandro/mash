#!/usr/bin/env bash
# Every dev tab's Fresh pane must come back after a Herdr restart, not only the
# first one.
#
# herdr-fresh-pane reports a resume command for its pane. Herdr 0.9.3 resumes at
# most one pane per reporter `--source`: with several panes reporting under the
# same name, a restart reopens the first and leaves every other one a bare
# shell, then drops their resume command from the next save. So the source has
# to be unique per pane. This drives the real wrapper against a throwaway Herdr
# server through two restarts -- the second proves a resumed pane re-reports.
#
# Needs the pinned Herdr on PATH; CI runners do not have it, so it skips there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
wrapper="$here/../helpers/herdr-fresh-pane"

if ! command -v herdr >/dev/null 2>&1; then
	printf 'SKIP: herdr is not installed\n'
	exit 0
fi

root="$(mktemp -d)"
cleanup() {
	HERDR_SOCKET_PATH="$root/h.sock" herdr server stop >/dev/null 2>&1 || true
	rm -rf -- "$root"
}
trap cleanup EXIT

# An isolated server: its own socket, config and session, never ~/.mash's.
unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH
export HERDR_SOCKET_PATH="$root/h.sock" HERDR_CLIENT_SOCKET_PATH="$root/c.sock"
export HERDR_CONFIG_PATH="$root/config.toml" XDG_CONFIG_HOME="$root/cfg"
mkdir -p "$root/bin" "$root/cfg" "$root/work"
printf 'onboarding = false\n' >"$HERDR_CONFIG_PATH"

# The wrapper resolves by name on resume and ends in `exec fresh`. Put the real
# wrapper on PATH, and a stand-in Fresh that stays running and is easy to spot.
ln -s "$wrapper" "$root/bin/herdr-fresh-pane"
printf '#!/bin/sh\necho FRESH-RUNNING; exec sleep 100000\n' >"$root/bin/fresh"
chmod +x "$root/bin/fresh"
export PATH="$root/bin:$PATH"

start() {
	(cd "$root/work" && herdr server >/dev/null 2>&1 &)
	for _ in $(seq 1 50); do
		herdr workspace list >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	echo 'FAIL: herdr server did not start' >&2
	exit 1
}

restart() {
	# The session writer is debounced; wait for it before stopping.
	sleep 6
	herdr server stop >/dev/null 2>&1 || true
	sleep 1
	start
	sleep 3
}

panes() { herdr pane list | grep -oE '"pane_id":"[^"]+"' | cut -d'"' -f4; }

running() { herdr pane read "$1" --source visible 2>/dev/null | grep -c FRESH-RUNNING || true; }

start
herdr workspace create --cwd "$root/work" >/dev/null
herdr tab create --cwd "$root/work" >/dev/null
herdr tab create --cwd "$root/work" >/dev/null
for pane in $(panes); do
	herdr pane run "$pane" 'herdr-fresh-pane .' >/dev/null
done
sleep 1

failed=0
for round in 1 2; do
	restart
	for pane in $(panes); do
		if [ "$(running "$pane")" -lt 1 ]; then
			echo "FAIL: after restart $round, $pane came back as a shell, not Fresh" >&2
			failed=1
		fi
	done
done
[ "$failed" -eq 0 ] || exit 1
printf 'PASS: every Fresh pane resumes after two Herdr restarts\n'
