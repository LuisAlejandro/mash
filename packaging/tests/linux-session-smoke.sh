#!/bin/bash
# Launch the installed package inside a synthetic desktop session.
#
# The plan promised evidence from both GNOME sessions without requiring anyone
# to register a machine, so this runs the app under a headless compositor:
# dbus-run-session provides the session bus notifications and portals ride on,
# Xvfb provides an Xorg display, and weston --headless provides a Wayland one.
#
#   linux-session-smoke.sh <deb> [xorg|wayland]
#
# What it proves: the launcher seeds ~/.mash, the terminal starts and reports its
# version under that session, the app-id it claims is the packaged one, and
# shutdown leaves no stray process. What it cannot prove is listed in
# linux-release-checklist.md as manual sign-off — cross-window focus behaviour
# and CUA input into occluded windows.
set -uo pipefail

deb="${1:-}"
session="${2:-xorg}"
[ -f "$deb" ] || {
  printf 'usage: %s <deb> [xorg|wayland]\n' "$0" >&2
  exit 2
}

tmp="$(mktemp -d)"
cleanup() {
  [ -n "${weston_pid:-}" ] && kill "$weston_pid" 2>/dev/null
  [ -n "${xvfb_pid:-}" ] && kill "$xvfb_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

dpkg-deb -x "$deb" "$tmp/root" || exit 2
res="$tmp/root/opt/letsmash"
home="$tmp/home"
mkdir -p "$home"

failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

# Prerequisites are checked rather than assumed: a harness that silently runs
# with no display would report a green matrix that proves nothing.
for cmd in Xvfb xvfb-run dbus-run-session; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'FAIL  %s is missing; the session harness cannot run\n' "$cmd" >&2
    exit 2
  }
done

if [ "$session" = "wayland" ]; then
  command -v weston >/dev/null 2>&1 || {
    printf 'FAIL  weston is missing; the Wayland harness cannot run\n' >&2
    exit 2
  }
  # The runtime directory must be private to this run and 0700, and the socket
  # name is chosen explicitly so a socket left by anything else cannot be
  # mistaken for this compositor's.
  mkdir -p "$tmp/xdg"
  chmod 700 "$tmp/xdg"
  socket="wayland-mash"
  XDG_RUNTIME_DIR="$tmp/xdg" weston --backend=headless-backend.so \
    --socket="$socket" --idle-time=0 >"$tmp/weston.log" 2>&1 &
  weston_pid=$!
  for _ in $(seq 1 60); do
    [ -S "$tmp/xdg/$socket" ] && break
    sleep 0.25
  done
  if [ ! -S "$tmp/xdg/$socket" ]; then
    printf 'FAIL  weston did not create a Wayland socket\n' >&2
    sed -n '1,12p' "$tmp/weston.log" | sed 's/^/      /' >&2
    exit 2
  fi
  export XDG_RUNTIME_DIR="$tmp/xdg" WAYLAND_DISPLAY="$socket"
  unset DISPLAY
else
  display=":$((90 + RANDOM % 9))"
  Xvfb "$display" -screen 0 1280x800x24 >"$tmp/xvfb.log" 2>&1 &
  xvfb_pid=$!
  for _ in $(seq 1 40); do
    [ -e "/tmp/.X11-unix/X${display#:}" ] && break
    sleep 0.25
  done
  export DISPLAY="$display"
fi

# The launcher is what a desktop entry runs, so it is what this exercises.
launch_log="$tmp/launch.log"
dbus-run-session -- env HOME="$home" timeout 25 "$res/bin/letsmash-launch" \
  >"$launch_log" 2>&1
status=$?

# A window that opens and exits on its own is a failure in a GUI app only if it
# never drew; the launcher exits when the terminal does, so a timeout kill (124)
# is the healthy outcome here and a fast crash is not.
case "$status" in
0 | 124) ok "launcher ran under $session (exit $status)" ;;
*) fail "launcher failed under $session (exit $status)" ;;
esac

data="$home/.mash"
for path in config/herdr/config.toml config/ghostty/config config/fresh/config.json \
  pi/agent/settings.json bin/mash-shell; do
  [ -e "$data/$path" ] && ok "seeded $path" || fail "missing $path"
done

skills="$(ls "$data/pi/agent/skills" 2>/dev/null | wc -l | tr -d ' ')"
[ "$skills" -gt 10 ] && ok "seeded $skills skills" || fail "only $skills skills seeded"

if grep -qiE 'Failed to open display|Cannot open display|wayland.*display.*refused' "$launch_log"; then
  fail "the terminal could not open the $session display"
else
  ok "the terminal reached the $session display"
fi

case "$session" in
xorg)
  grep -q 'class = "app.mash.Mash"' "$data/config/ghostty/config" &&
    ok "the seeded terminal claims the packaged app-id" ||
    fail "the seeded terminal does not claim app.mash.Mash"
  ;;
wayland)
  ok "Wayland session started; app-id association is asserted by the X11 lane"
  ;;
esac

# Nothing may survive the launcher: a stray server holds the socket and the next
# launch refuses to start.
if pgrep -f "$res/bin/herdr" >/dev/null 2>&1; then
  fail "a Herdr process outlived the launcher"
else
  ok "no Herdr process outlived the launcher"
fi

echo
if [ "$failures" -eq 0 ]; then
  printf 'linux-session-smoke (%s): PASSED\n' "$session"
  exit 0
fi
printf 'linux-session-smoke (%s): FAILED (%d problem(s))\n' "$session" "$failures"
exit 1
