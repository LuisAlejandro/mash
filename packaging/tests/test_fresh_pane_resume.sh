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
# Stand in for mash-shell's one-shot early Fresh branch; unlike the real
# mash-shell this must not point the isolated server at the live ~/.mash socket.
# Untagged panes still start a plain shell, never the account's.
cat >"$root/bin/pane-shell" <<'EOF'
#!/bin/sh
if [ "${MASH_DEV_TAB_FRESH:-}" = 1 ]; then
  printf 1 >>"${0%/*}/early-starts"
  unset MASH_DEV_TAB_FRESH
  herdr-fresh-pane . || true
fi
exec /bin/sh
EOF
chmod +x "$root/bin/pane-shell"
printf 'onboarding = false\n\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "%s/bin/pane-shell"\n' "$root" \
	>"$HERDR_CONFIG_PATH"

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
	# Resuming a pane spawns its command and waits for output, which takes longer
	# on a loaded machine than any fixed sleep can promise. Wait for the panes
	# themselves, so the suite reports a pane that never came back rather than one
	# that was merely slow.
	wait_for_fresh
}

# Give every pane up to ~20s to report Fresh. Returns as soon as all of them do.
wait_for_fresh() {
	local attempt pane ready
	for attempt in $(seq 1 40); do
		ready=1
		for pane in $(panes); do
			[ "$(running "$pane")" -ge 1 ] || ready=0
		done
		[ "$ready" = 1 ] && return 0
		sleep 0.5
	done
	return 1
}

panes() { herdr pane list | grep -oE '"pane_id":"[^"]+"' | cut -d'"' -f4; }

running() { herdr pane read "$1" --source visible 2>/dev/null | grep -c FRESH-RUNNING || true; }

start
herdr workspace create --cwd "$root/work" >/dev/null
# A scripted dev tab runs Fresh through --env, before an interactive shell
# can show a prompt. The other panes cover the existing pane-run resume path.
created="$(herdr tab create --cwd "$root/work" --env MASH_DEV_TAB_FRESH=1)"
early="$(printf '%s' "$created" | grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4)"
[ -n "$early" ] || { echo 'FAIL: early Fresh pane has no id' >&2; exit 1; }
herdr tab create --cwd "$root/work" >/dev/null
for pane in $(panes); do
	[ "$pane" = "$early" ] || herdr pane run "$pane" 'herdr-fresh-pane .' >/dev/null
done
# Prove the stand-in Fresh is what the panes actually run. Without this the
# suite could pass against the real editor, or fail for a shadowed PATH rather
# than a broken resume.
if ! wait_for_fresh; then
	echo 'FAIL: a pane did not start the stand-in Fresh before any restart' >&2
	for pane in $(panes); do
		printf '  %s: %s\n' "$pane" "$(herdr pane read "$pane" --source visible 2>/dev/null | tail -1)" >&2
	done
	exit 1
fi

# The tab's first paint must not include the prompt or the typed command.
[ "$(wc -c <"$root/bin/early-starts")" -eq 1 ] || {
	echo 'FAIL: early Fresh ran more than once' >&2
	exit 1
}
if herdr pane read "$early" --source recent 2>/dev/null | grep -q 'herdr-fresh-pane \.'; then
	echo 'FAIL: early Fresh tab echoed its launch command' >&2
	exit 1
fi

failed=0
for round in 1 2; do
	restart
	[ "$(wc -c <"$root/bin/early-starts")" -eq 1 ] || {
		echo 'FAIL: one-shot tab environment relaunched Fresh on restore' >&2
		failed=1
	}
	for pane in $(panes); do
		if [ "$(running "$pane")" -lt 1 ]; then
			echo "FAIL: after restart $round, $pane came back as a shell, not Fresh" >&2
			failed=1
		fi
	done
done
[ "$failed" -eq 0 ] || exit 1
printf 'PASS: every Fresh pane resumes after two Herdr restarts\n'
