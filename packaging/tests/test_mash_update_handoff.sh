#!/usr/bin/env bash
# The update must survive stopping the Herdr server it was confirmed in.
#
# mash-update-verify runs in a Herdr pane (the update popup). The swap helper's
# first step stops Herdr, and Herdr ends every process a pane started, so a
# helper started as a child of the pane -- 0.2.0 used nohup -- died there: Mash
# closed, nothing was swapped, and nothing reopened it. The suites that stub
# every command could not see this, because nothing in them stops a real Herdr.
#
# This drives the real handoff: a real throwaway Herdr server, a pane that
# starts the swap helper exactly as mash-update-verify does, and the helper's
# own `herdr server stop`. The helper must outlive the server and finish.
#
# Needs a real Herdr and launchd, so it runs on macOS with the pinned Herdr on
# PATH, and skips elsewhere.
set -euo pipefail

if [ "$(uname -s)" != Darwin ] || ! command -v herdr >/dev/null 2>&1; then
	printf 'SKIP: needs macOS and herdr on PATH\n'
	exit 0
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
verify="$repo/packaging/helpers/mash-update-verify"
root="$(mktemp -d /tmp/mash-handoff.XXXXXX)"
label="app.mash.update"
uid="$(id -u)"
cleanup() {
	HERDR_SOCKET_PATH="$root/h.sock" herdr server stop >/dev/null 2>&1 || true
	launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
	rm -rf "$root"
}
trap cleanup EXIT
# A real update in progress owns this label; never touch it.
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
	printf 'SKIP: an update job is loaded right now\n'
	exit 0
fi

unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH
export HERDR_SOCKET_PATH="$root/h.sock" HERDR_CLIENT_SOCKET_PATH="$root/c.sock"
export HERDR_CONFIG_PATH="$root/config.toml" XDG_CONFIG_HOME="$root/cfg"
mkdir -p "$root/cfg" "$root/work" "$root/bin"
printf 'onboarding = false\n\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "/bin/sh"\n' \
	>"$HERDR_CONFIG_PATH"

# launchd starts jobs with a minimal PATH, so the stand-in calls Herdr by
# absolute path, exactly as the real helper does with $dest/.../bin/herdr.
herdr_bin="$(command -v herdr)"

# Stands in for mash-update-apply. It does what the real one does first --
# stop the Herdr server -- and then records that it lived long enough to reach
# the swap. The handoff, not the swap, is what this test is about.
cat >"$root/fake-apply" <<EOF
#!/bin/bash
HERDR_SOCKET_PATH="$root/h.sock" "$herdr_bin" server stop >/dev/null 2>&1
for _ in \$(seq 1 40); do HERDR_SOCKET_PATH="$root/h.sock" "$herdr_bin" workspace list >/dev/null 2>&1 || break; sleep 0.25; done
sleep 2
echo "reached the swap after herdr stopped" >"$root/finished"
EOF
chmod +x "$root/fake-apply"

# The handoff, cut out of mash-update-verify verbatim: from writing the job to
# launchctl bootstrap. Running the rest of verify would need a signed DMG.
handoff="$root/handoff"
awk '/^job="\$work\/app.mash.update.plist"$/,/^exit 0$/' "$verify" >"$handoff.body"
grep -q 'launchctl bootstrap' "$handoff.body" || {
	echo "FAIL: could not find the launchd handoff in mash-update-verify" >&2
	exit 1
}
{
	echo '#!/bin/bash'
	echo 'fail() { echo "FAIL: $1" >&2; exit 1; }'
	echo 'cleanup() { :; }'
	# shellcheck disable=SC2016
	echo 'apply="$1" staged="$2" app="$3" d="$4" work="$5" candidate="$6"'
	cat "$handoff.body"
} >"$handoff"
chmod +x "$handoff"
mkdir -p "$root/data/local/state" "$root/w"

(cd "$root/work" && herdr server >/dev/null 2>&1 &)
for _ in $(seq 1 80); do herdr workspace list >/dev/null 2>&1 && break; sleep 0.25; done
herdr workspace create --cwd "$root/work" >/dev/null
pane="$(herdr pane list | grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4)"
herdr pane run "$pane" "$handoff $root/fake-apply $root/w/Mash.app /Applications/Mash.app $root/data $root/w 9.9.9" >/dev/null

for _ in $(seq 1 120); do
	[ -f "$root/finished" ] && break
	sleep 0.25
done
if [ ! -f "$root/finished" ]; then
	echo "FAIL: the swap helper died with the Herdr server it stopped" >&2
	exit 1
fi
# The socket file can outlive the server, so ask the server itself.
if herdr workspace list >/dev/null 2>&1; then
	echo "FAIL: the Herdr server was still running" >&2
	exit 1
fi
printf 'PASS: the swap helper outlives the Herdr server it stops\n'
