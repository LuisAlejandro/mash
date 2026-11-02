#!/usr/bin/env bash
# A restored pi pane must come back as its conversation and NOTHING may be typed
# into it. Two restore paths can reopen the same pane, and they exist for
# different failures:
#
#   Herdr's own record  -- an ordinary restart, where pi is still running when
#                          Herdr saves, so `agent_resume` is in session.json and
#                          Herdr replays it itself.
#   Mash's ledger       -- a macOS logout, where pi is killed about twenty
#                          seconds before Herdr stops. Herdr keeps a resume
#                          command only while the agent that reported it runs,
#                          so it drops the command and saves the pane as a plain
#                          shell (bcb9a9f). The shell a restore leaves behind
#                          reopens pi from $XDG_STATE_HOME/mash/pane-resume.
#
# When both survive they race: the ledger reopens pi from the pane's shell
# startup, and Herdr then replays its own record into that pane -- which is now
# pi's prompt, not a shell. The conversation comes back correct with
# `pi --session <file>` sitting in the composer. That is what this pins.
#
# SCOPE -- this suite covers the ORDINARY RESTART only, where both records
# survive. It deliberately does not simulate a logout: that shape depends on
# Herdr noticing, by its own polling and screen reading, that the agent is gone,
# and a test that drives those internals asserts Herdr's behaviour rather than
# Mash's. The ledger's own half of the contract -- what it reopens, once, and
# when it declines -- is covered without a server in test_mash_pane_resume.sh.
# A fix for the race must keep BOTH suites passing.
#
# Needs the pinned Herdr on PATH; CI runners do not have it, so it skips there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
helper="$here/../helpers/mash-pane-resume"

if ! command -v herdr >/dev/null 2>&1; then
	printf 'SKIP: herdr is not installed\n'
	exit 0
fi

root="$(mktemp -d)"
export HERDR_SOCKET_PATH="$root/h.sock" HERDR_CLIENT_SOCKET_PATH="$root/c.sock"
export HERDR_CONFIG_PATH="$root/config.toml"
export XDG_CONFIG_HOME="$root/cfg" XDG_STATE_HOME="$root/state"
cleanup() {
	herdr server stop >/dev/null 2>&1 || true
	rm -rf -- "$root"
}
trap cleanup EXIT
# An isolated server: never ~/.mash's socket, config, session or ledger.
unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH
mkdir -p "$root/bin" "$root/cfg" "$root/work" "$root/state/mash/pane-resume" "$root/starts"

# The pane shell stands in for mash-shell: the real one would re-point this
# server's socket back at ~/.mash. It runs the REAL ledger helper, which is the
# part under test, then falls back to a plain shell exactly as a pane does.
cat >"$root/bin/pane-shell" <<'EOF'
#!/bin/bash
export PATH="${0%/*}:$PATH"
mash-pane-resume || true
exec /bin/sh
EOF
# A stand-in pi: it reports its state and resume command the way Mash's patched
# herdr-agent-state.ts does, writes the same ledger entry, then echoes whatever
# is typed at it -- which is how a replayed command becomes visible. The
# reporter source is per-pane: Herdr resumes at most one pane per source.
cat >"$root/bin/pi" <<EOF
#!/bin/bash
# Clear the screen, as the real pi's TUI does on startup.
printf '\033[H\033[2J\033[3J'
# Count launches in a file, not on screen: Herdr reads the pane to decide what
# is running in it, so counting must not change what it sees.
printf '%s\n' "\$HERDR_PANE_ID" >>"$root/starts/\${HERDR_PANE_ID/:/_}"
printf 'AGENT-UP\n'
ledger="\$XDG_STATE_HOME/mash/pane-resume/\${HERDR_PANE_ID/:/_}"
seq="\$(date +%s)"
report() { herdr pane report-agent "\$HERDR_PANE_ID" --source "mash-test:\$HERDR_PANE_ID" \\
	--agent pi --state idle --seq "\$1" "\${@:2}" >/dev/null 2>&1 || true; }
# State first, then the resume command: Herdr accepts resume_argv only from a
# reporter that already holds the pane.
report "\$seq"
report "\$((seq + 1))" -- pi --session "$root/session.jsonl"
mkdir -p "\${ledger%/*}"
printf 'pi\n--session\n%s\n' "$root/session.jsonl" >"\$ledger"
# Anything replayed into a pi that is already running lands here.
while IFS= read -r line; do printf 'AGENT-INPUT:<%s>\n' "\$line"; done
EOF
ln -sf "$helper" "$root/bin/mash-pane-resume"
chmod +x "$root/bin/pane-shell" "$root/bin/pi"
export PATH="$root/bin:$PATH"
printf 'conversation\n' >"$root/session.jsonl"
printf 'onboarding = false\n\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "%s/bin/pane-shell"\n' \
	"$root" >"$HERDR_CONFIG_PATH"

start() {
	(cd "$root/work" && herdr server >/dev/null 2>&1 &)
	for _ in $(seq 1 50); do
		herdr workspace list >/dev/null 2>&1 && return 0
		sleep 0.1
	done
	echo 'FAIL: herdr server did not start' >&2
	exit 1
}

# How many times this pane has started pi, and whether anything was typed into
# a running one. The first is a file the server cannot see; the second is the
# pane's own screen, which is where a replayed command shows up.
pi_starts() {
	local file="$root/starts/${1/:/_}"
	[ -f "$file" ] && wc -l <"$file" | tr -d ' ' || echo 0
}
replayed_input() { herdr pane read "$1" --source recent 2>/dev/null | grep -c 'AGENT-INPUT:' || true; }

# Wait for pi rather than sleeping a fixed time: a loaded machine is slower than
# any constant, and a pane that never came back must fail as itself.
# $2 is how many starts to wait for; a restore adds one to what was there.
wait_for_pi() {
	for _ in $(seq 1 60); do
		[ "$(pi_starts "$1")" -ge "${2:-1}" ] && return 0
		sleep 0.25
	done
	return 1
}

new_pane() {
	herdr workspace create --cwd "$root/work" |
		grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4
}

# Herdr's saved state names panes by an internal key, not by the public
# "w1:p1" id, so this finds the pane through its workspace.
saved_resume() {
	python3 - "$XDG_CONFIG_HOME" "$1" <<'PY'
import json, pathlib, sys
wanted_workspace = sys.argv[2].split(":")[0]
for path in pathlib.Path(sys.argv[1]).rglob("session.json"):
    state = json.loads(path.read_text())
    for workspace in state.get("workspaces", []):
        if workspace.get("id") != wanted_workspace:
            continue
        for tab in workspace.get("tabs", []):
            for pane in tab.get("panes", {}).values():
                print("yes" if pane.get("agent_resume") else "no")
                raise SystemExit
print("no")
PY
}

failed=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok   - %s\n' "$1"
	else
		printf 'FAIL - %s\n       want %s, got %s\n' "$1" "$3" "$2" >&2
		failed=1
	fi
}

start

# pi is still running when the server stops, so Herdr saves its own record and
# the ledger entry is on disk too -- the state every ordinary restart is in.
pane="$(new_pane)"
herdr pane run "$pane" "pi --session $root/session.jsonl" >/dev/null
wait_for_pi "$pane" || { echo 'FAIL: pi never started in the pane' >&2; exit 1; }

# The session writer is debounced; let it save before stopping the server.
sleep 6
herdr server stop >/dev/null 2>&1 || true
sleep 1

# Both records must be present, or this is not the case it claims to be.
check 'the restart keeps Herdr own resume record' "$(saved_resume "$pane")" yes
check 'the restart keeps the Mash ledger entry' \
	"$([ -f "$XDG_STATE_HOME/mash/pane-resume/${pane/:/_}" ] && echo yes || echo no)" yes

start
wait_for_pi "$pane" 2 || echo 'FAIL: the pane came back without pi' >&2
# Let a second restore -- or a replayed command -- land before counting.
sleep 3

check 'the restart reopens pi exactly once' "$(pi_starts "$pane")" 2
check 'the restart types nothing into the restored pi' "$(replayed_input "$pane")" 0

[ "$failed" -eq 0 ] || exit 1
printf 'PASS: a restored pi pane is reopened once, with an empty prompt\n'
