#!/usr/bin/env bash
# The first-launch wizard chooses the keybinding mode after the terminal has
# already read its config, so the pane must ask that exact terminal to reload.
# Guards both halves: the signal goes to MASH_TERMINAL_PID, and nothing is
# signalled on an ordinary launch (no setup handoff marker).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pane="$here/../herdr-pane"

# The handoff block only; running all of herdr-pane would isolate against the
# real ~/.mash. Fails loudly if the block is renamed or moved.
snippet="$(sed -n '/^once=/,/^fi$/p' "$pane")"
case "$snippet" in
*"kill -USR2"*) ;;
*)
  echo 'FAIL: setup handoff block not found in herdr-pane' >&2
  exit 1
  ;;
esac

run() { # run <home> [pid] -> prints the signals the block sent
  local home="$1" pid="${2:-}"
  local bin_dir
  bin_dir="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"$bin_dir/herdr"
  chmod +x "$bin_dir/herdr"
  signals="$(mktemp)"
  # shellcheck disable=SC2317  # called from the evaluated snippet
  kill() { printf '%s\n' "$*" >>"$signals"; }
  MASH_TERMINAL_PID="$pid" eval "$snippet"
  cat "$signals"
  rm -rf -- "$bin_dir" "$signals"
}

home="$(mktemp -d)"
trap 'rm -rf -- "$home"' EXIT
mkdir -p "$home/.mash/setup"
: >"$home/.mash/setup/open-workspace-once"
got="$(run "$home" 4242)"
[ "$got" = "-USR2 4242" ] || {
  echo "FAIL: expected the owning terminal to be signalled, got '$got'" >&2
  exit 1
}

# No marker: a later launch already has the right config and must not signal.
got="$(run "$home" 4242)"
[ -z "$got" ] || {
  echo "FAIL: signalled outside the setup handoff: '$got'" >&2
  exit 1
}

printf 'PASS: setup handoff reloads only the terminal that owns the pane\n'
