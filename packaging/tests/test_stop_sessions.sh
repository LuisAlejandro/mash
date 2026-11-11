#!/usr/bin/env bash
# "Quit and Stop Sessions" ends Mash's Herdr server -- and nothing else.
#
# Mash has two exits and they are not the same. The close button and Cmd+Q /
# Ctrl+Shift+Q end this window's Herdr client and leave the server, its panes
# and their agents running, so the next launch reattaches. The chord this suite
# covers is the second, explicit exit: it runs `herdr server stop`, the client
# then exits on its own, the window closes, and the app quits with it.
#
# Three things are pinned here:
#
#   1. The helper really stops a running server.
#   2. It refuses any socket that is not $HOME/.mash/run/herdr.sock, and refuses
#      without ever invoking herdr. This is the accident it exists to prevent:
#      a "stop" that reaches a personal Herdr server, a second Mash instance or
#      a scratch server ends work that has nothing to do with this window.
#   3. Both platform configs and the Native keymap still bind the chord to the
#      helper. Mash's menus replay the chord rather than calling anything, so a
#      renamed chord or command leaves a menu item that silently does nothing
#      (packaging/menu-chords.py checks the menu half).
#
# Needs the pinned Herdr on PATH; CI runners do not have it, so it skips there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
helper="$here/../helpers/mash-stop-sessions"
defaults="$here/../defaults/herdr"

if ! command -v herdr >/dev/null 2>&1; then
	printf 'SKIP: herdr is not installed\n'
	exit 77
fi
herdr_bin="$(command -v herdr)"

root="$(mktemp -d)"
# The helper accepts one socket path, and it is the one under $HOME, so the test
# moves HOME into the scratch tree rather than teaching the test a bypass the
# product does not have.
export HOME="$root/home"
mkdir -p "$HOME/.mash/run" "$root/bin" "$root/cfg" "$root/state" "$root/data"
export XDG_CONFIG_HOME="$root/cfg" XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data"
export HERDR_CONFIG_PATH="$root/config.toml"
export HERDR_SOCKET_PATH="$HOME/.mash/run/herdr.sock"
# An isolated server: never ~/.mash's, and not a nested client of this pane's.
unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH HERDR_CLIENT_SOCKET_PATH

cleanup() {
	"$herdr_bin" server stop >/dev/null 2>&1 || true
	rm -rf -- "$root"
}
trap cleanup EXIT

cat >"$HERDR_CONFIG_PATH" <<'EOF'
onboarding = false
[update]
version_check = false
manifest_check = false
[terminal]
shell_mode = "non_login"
default_shell = "/bin/sh"
EOF

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# 1. A running server stops, and stops because the helper asked it to.
"$herdr_bin" server >"$root/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
	[ -S "$HERDR_SOCKET_PATH" ] && break
	sleep 0.1
done
[ -S "$HERDR_SOCKET_PATH" ] || fail "the scratch herdr server never came up"
kill -0 "$server_pid" 2>/dev/null || fail "the scratch herdr server exited at once"

HERDR_BIN_PATH="$herdr_bin" "$helper" || fail "the helper did not stop a running server"
for _ in $(seq 1 100); do
	[ -S "$HERDR_SOCKET_PATH" ] || break
	sleep 0.1
done
[ ! -S "$HERDR_SOCKET_PATH" ] || fail "the helper returned but the server's socket is still there"
wait "$server_pid" 2>/dev/null || true

# 2. A foreign socket is refused, and herdr is never handed it. The stub proves
#    the refusal happens before the call rather than after a failed one.
cat >"$root/bin/herdr" <<EOF
#!/bin/sh
: >"$root/invoked"
exit 0
EOF
chmod +x "$root/bin/herdr"
PATH="$root/bin:$PATH" HERDR_BIN_PATH="" HERDR_SOCKET_PATH="$root/other.sock" \
	"$helper" >/dev/null 2>"$root/refused.err" && fail "the helper stopped a socket outside \$HOME/.mash/run"
[ -e "$root/invoked" ] && fail "the helper invoked herdr before refusing a foreign socket"
grep -q 'refusing' "$root/refused.err" || fail "the refusal did not say why"

PATH="$root/bin:$PATH" HERDR_BIN_PATH="" env -u HERDR_SOCKET_PATH \
	"$helper" >/dev/null 2>&1 && fail "the helper ran with no HERDR_SOCKET_PATH"
[ -e "$root/invoked" ] && fail "the helper invoked herdr with no HERDR_SOCKET_PATH"

# 3. The bindings both platforms ship, and the Native key that stands in for
#    them there. The chords are what Mash's menus replay, so the item, the
#    binding and this helper have to agree.
grep -q 'key = "cmd+alt+q"' "$defaults/config.toml" ||
	fail "defaults/herdr/config.toml no longer binds cmd+alt+q"
grep -q 'key = "ctrl+alt+q"' "$defaults/config.linux.toml" ||
	fail "defaults/herdr/config.linux.toml no longer binds ctrl+alt+q"
for config in config.toml config.linux.toml; do
	grep -q 'command = .*mash-stop-sessions' "$defaults/$config" ||
		fail "$config no longer runs mash-stop-sessions"
	grep -q 'description = "Quit and stop sessions"' "$defaults/$config" ||
		fail "$config no longer names the command for the Native keymap"
done
grep -q '"Quit and stop sessions" = "prefix+shift+q"' "$defaults/keys.native.toml" ||
	fail "keys.native.toml no longer binds the command on a prefix key"

printf 'PASS: quit and stop sessions\n'
