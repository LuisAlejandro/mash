#!/usr/bin/env bash
# mash-pane-starting says a pane is starting, before the program owns the screen.
#
# What it has to get right:
#
#   * the pane content becomes one intentional line, not the prompt plus the
#     command that was typed into it
#   * a Herdr state label is set for the part that cannot be drawn here -- the
#     program's own startup -- and carries a TTL, so a start that dies cannot
#     leave "starting" on the pane forever
#   * it never fails a launch: no terminal, no Herdr, no catalog, no problem
#   * a pipe or a scripted run keeps its output, since clearing would destroy it
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
helper="$root/packaging/helpers/mash-pane-starting"
[ -x "$helper" ] || {
  echo "mash-pane-starting is missing or not executable" >&2
  exit 1
}
grep -qx '  mash-pane-starting' "$root/packaging/build.sh" || {
  echo "macOS build does not ship mash-pane-starting" >&2
  exit 1
}
# Both start paths announce themselves; without that the pane keeps showing the
# shell that asked for the program.
grep -q 'mash-pane-starting editor' "$root/packaging/helpers/herdr-fresh-pane" || {
  echo "herdr-fresh-pane does not announce the editor" >&2
  exit 1
}
grep -q 'mash-pane-starting agent' "$root/packaging/helpers/herdr-agent-start" || {
  echo "herdr-agent-start does not announce the agent" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"
cp "$helper" "$bin/mash-pane-starting"
chmod +x "$bin/mash-pane-starting"

# A stand-in lib.sh: mash-pane-starting only needs these three names.
cat >"$bin/lib.sh" <<'SH'
mash_real_home() { printf '%s\n' "${FAKE_HOME:-/tmp}"; }
mash_messages_bind() { :; }
mash_say() { printf '%s' 'Starting the editor...'; }
SH

# A fake herdr: records the label it was asked to set.
cat >"$bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_HERDR_LOG"
SH
chmod +x "$bin/herdr"

run() {
  : >"$tmp/herdr.log"
  env MASH_BIN="$bin" HERDR_BIN_PATH="$bin/herdr" FAKE_HERDR_LOG="$tmp/herdr.log" \
    "$bin/mash-pane-starting" "$@"
}

# --- the label spans the program's startup, and expires ---------------------
run editor w1:p2 >/dev/null
grep -q 'report-metadata w1:p2' "$tmp/herdr.log" || {
  echo "no pane label was set: $(cat "$tmp/herdr.log")" >&2
  exit 1
}
grep -q -- '--state-label starting=' "$tmp/herdr.log" || {
  echo "the label does not name a starting state: $(cat "$tmp/herdr.log")" >&2
  exit 1
}
grep -q -- '--ttl-ms 15000' "$tmp/herdr.log" || {
  echo "the label has no TTL, so a failed start would leave it forever" >&2
  exit 1
}

# --- a piped run keeps its output; a terminal gets the line ----------------
piped="$(run editor w1:p2)"
[ -z "$piped" ] || {
  echo "a piped run was given screen-clearing output: $(printf '%q' "$piped")" >&2
  exit 1
}

# --- the pane id falls back to the calling pane ----------------------------
: >"$tmp/herdr.log"
HERDR_PANE_ID="w9:p9" MASH_BIN="$bin" HERDR_BIN_PATH="$bin/herdr" \
  FAKE_HERDR_LOG="$tmp/herdr.log" "$bin/mash-pane-starting" agent >/dev/null
grep -q 'report-metadata w9:p9' "$tmp/herdr.log" || {
  echo "the label did not fall back to HERDR_PANE_ID: $(cat "$tmp/herdr.log")" >&2
  exit 1
}

# --- no Herdr, no lib.sh, no catalog: still exits 0 -----------------------
MASH_BIN="$tmp/nothing" HERDR_BIN_PATH="$bin/herdr" FAKE_HERDR_LOG=/dev/null \
  "$bin/mash-pane-starting" editor w1:p2 >/dev/null || {
  echo "a missing lib.sh failed the helper" >&2
  exit 1
}
MASH_BIN="$bin" HERDR_BIN_PATH="$tmp/missing-herdr" FAKE_HERDR_LOG=/dev/null \
  "$bin/mash-pane-starting" editor w1:p2 >/dev/null || {
  echo "a missing herdr failed the helper" >&2
  exit 1
}

echo "mash-pane-starting: ok"
