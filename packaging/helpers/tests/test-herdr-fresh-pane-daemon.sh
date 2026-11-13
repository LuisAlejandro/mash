#!/usr/bin/env bash
# herdr-fresh-pane --daemon attaches to the shared Fresh daemon for a directory.
#
# The behaviour that matters:
#
#   * only a dev tab asks for the daemon; every other caller keeps a private
#     editor, because a shared one would make a telescope pane betray whatever
#     dev tab it sits in
#   * a daemon pane is tagged, which is the only thing the split-ratio sync acts
#     on: tagging is how "this editor is shared" is expressed
#   * the resume command keeps the flag, or a Herdr restart brings the pane back
#     private and it silently stops matching its tab
#
# A fake herdr and fresh stand in for the real ones, so this runs anywhere.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
helper="$root/packaging/helpers/herdr-fresh-pane"
[ -x "$helper" ] || {
  echo "herdr-fresh-pane is missing or not executable" >&2
  exit 1
}
grep -qx '  herdr-fresh-pane' "$root/packaging/build.sh" || {
  echo "macOS build does not ship herdr-fresh-pane" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$helper" "$tmp/bin/herdr-fresh-pane"
chmod +x "$tmp/bin/herdr-fresh-pane"

# A fake herdr: answers `pane current` and records every other call.
cat >"$tmp/bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_HERDR_LOG"
case "$1 $2" in
"pane current") printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
"pane layout")
  # FAKE_LAYOUT picks the tab's shape: dev (w1:p9 left of a right split),
  # devright (w1:p9 on the right), or single (one pane).
  case "${FAKE_LAYOUT:-single}" in
  dev) printf '%s\n' '{"result":{"layout":{"panes":[{"pane_id":"w1:p9","rect":{"x":0}},{"pane_id":"w1:p8","rect":{"x":120}}],"splits":[{"direction":"right"}]}}}' ;;
  devright) printf '%s\n' '{"result":{"layout":{"panes":[{"pane_id":"w1:p8","rect":{"x":0}},{"pane_id":"w1:p9","rect":{"x":120}}],"splits":[{"direction":"right"}]}}}' ;;
  down) printf '%s\n' '{"result":{"layout":{"panes":[{"pane_id":"w1:p9","rect":{"x":0}},{"pane_id":"w1:p8","rect":{"x":0}}],"splits":[{"direction":"down"}]}}}' ;;
  complex) printf '%s\n' '{"result":{"layout":{"panes":[{"pane_id":"w1:p9","rect":{"x":0}},{"pane_id":"w1:p8","rect":{"x":120}},{"pane_id":"w1:p7","rect":{"x":120}}],"splits":[{"direction":"right"},{"direction":"down"}]}}}' ;;
  *) printf '%s\n' '{"result":{"layout":{"panes":[{"pane_id":"w1:p9","rect":{"x":0}}],"splits":[]}}}' ;;
  esac ;;
esac
exit 0
SH
chmod +x "$tmp/bin/herdr"

# A fake fresh: records how it was invoked, then exits successfully.
cat >"$tmp/bin/fresh" <<'SH'
#!/bin/sh
printf 'fresh %s\n' "$*" >>"$FAKE_FRESH_LOG"
printf 'entry=%s\n' "${MASH_FRESH_DIRECTORY_ENTRY:-unset}" >>"$FAKE_FRESH_LOG"
SH
chmod +x "$tmp/bin/fresh"

# A PTY proxy must not sit in Fresh's foreground slot: Herdr would see the
# loader instead of Fresh, breaking PID-based viewer and parking detection.
cat >"$tmp/bin/mash-pane-runner" <<'SH'
#!/bin/sh
echo 'Fresh must exec directly rather than run behind a PTY proxy' >&2
exit 42
SH
chmod +x "$tmp/bin/mash-pane-runner"

run() {
  : >"$tmp/herdr.log"
  : >"$tmp/fresh.log"
  PATH="$tmp/bin:$PATH" MASH_BIN="$tmp/bin" HERDR_BIN_PATH="$tmp/bin/herdr" \
    FAKE_HERDR_LOG="$tmp/herdr.log" FAKE_FRESH_LOG="$tmp/fresh.log" FAKE_LAYOUT="${LAYOUT:-single}" \
    "$tmp/bin/herdr-fresh-pane" "$@"
}

# --- a dev tab attaches to the shared daemon --------------------------------
run --daemon .
grep -qx 'fresh -a' "$tmp/fresh.log" || {
  echo "a dev tab did not attach to the daemon: $(cat "$tmp/fresh.log")" >&2
  exit 1
}
grep -qx 'entry=1' "$tmp/fresh.log" || exit 1
grep -q 'report-metadata w1:p9 .*mash-fresh-daemon=1' "$tmp/herdr.log" || {
  echo "a daemon pane was not tagged for the split sync: $(cat "$tmp/herdr.log")" >&2
  exit 1
}
grep -q 'report-agent w1:p9 .*-- herdr-fresh-pane --daemon \.' "$tmp/herdr.log" || {
  echo "the resume command lost --daemon: $(cat "$tmp/herdr.log")" >&2
  exit 1
}

# The directory argument is dropped on purpose: `fresh -a NAME` would take it as
# a daemon name, and the daemon never receives files anyway.
grep -q 'fresh -a \.' "$tmp/fresh.log" && {
  echo "the trailing '.' was passed where -a would read it as a session name" >&2
  exit 1
}

# --- anything else keeps a private editor ----------------------------------
run .
grep -qx 'fresh \.' "$tmp/fresh.log" || {
  echo "a private pane did not get its directory argument: $(cat "$tmp/fresh.log")" >&2
  exit 1
}
grep -qx 'entry=unset' "$tmp/fresh.log" || exit 1
grep -q 'mash-fresh-daemon' "$tmp/herdr.log" && {
  echo "a private editor was tagged as shared: $(cat "$tmp/herdr.log")" >&2
  exit 1
}
grep -q 'report-agent w1:p9 .*-- herdr-fresh-pane \.' "$tmp/herdr.log" || {
  echo "a private pane's resume command is wrong: $(cat "$tmp/herdr.log")" >&2
  exit 1
}

# --- the callers that build dev tabs all ask for the daemon -----------------
for file in packaging/helpers/herdr-dev-tab-fill \
  packaging/defaults/plugins/herdr-workspace/config.yaml \
  packaging/mash-shell \
  packaging/plugins/fork-from-message/scripts/fork_from_message.py; do
  grep -q 'herdr-fresh-pane --daemon \.' "$root/$file" || {
    echo "$file builds a dev tab without --daemon" >&2
    exit 1
  }
done

# --- a bare `.` that IS a dev tab shares too --------------------------------
# Herdr replays the resume command a pane last reported, so a tab from before
# the shared editor replays `herdr-fresh-pane .` forever. Telescope's new-tab
# path and sesh build the same layout with that same bare command.
LAYOUT=dev run .
grep -qx 'fresh -a' "$tmp/fresh.log" || {
  echo "a dev tab's bare resume stayed private: $(cat "$tmp/fresh.log")" >&2
  exit 1
}
grep -q 'report-agent w1:p9 .*-- herdr-fresh-pane --daemon \.' "$tmp/herdr.log" || {
  echo "a migrated dev tab did not report the shared resume command" >&2
  exit 1
}
grep -q 'report-metadata w1:p9 .*mash-fresh-daemon=1' "$tmp/herdr.log" || {
  echo "a migrated dev tab was not tagged for the split sync" >&2
  exit 1
}
# Fresh on the right is not Mash's layout: keep it private.
LAYOUT=devright run .
grep -qx 'fresh \.' "$tmp/fresh.log" || {
  echo "a right-hand Fresh pane was taken for a dev tab" >&2
  exit 1
}

# Explicit daemon resumes are idempotent: no layout inference is needed again.
LAYOUT=single run --daemon .
grep -qx 'fresh -a' "$tmp/fresh.log" || exit 1
if grep -q '^pane layout' "$tmp/herdr.log"; then
  echo 'an explicit daemon resume unnecessarily inferred the layout' >&2
  exit 1
fi

# Only the legacy directory launch is upgraded. Never swallow file arguments,
# attach custom split layouts, or turn a deliberate bare launch into a daemon.
LAYOUT=dev run report.md
grep -qx 'fresh report.md' "$tmp/fresh.log" || exit 1
LAYOUT=dev run
grep -qx 'fresh ' "$tmp/fresh.log" || exit 1
for shape in down complex; do
  LAYOUT="$shape" run .
  grep -qx 'fresh \.' "$tmp/fresh.log" || exit 1
done

# --- the syncer is shipped, started, and independent of the daemon patch ---
grep -qx '  mash-fresh-split-sync' "$root/packaging/build.sh" || {
  echo "macOS build does not ship mash-fresh-split-sync" >&2
  exit 1
}
grep -q 'mash-fresh-split-sync' "$root/packaging/herdr-pane" || {
  echo "the launcher never starts the split-ratio sync" >&2
  exit 1
}

# --- the parker is shipped and started too --------------------------------
grep -qx '  mash-dev-tab-park' "$root/packaging/build.sh" || {
  echo "macOS build does not ship mash-dev-tab-park" >&2
  exit 1
}
grep -q 'mash-dev-tab-park' "$root/packaging/herdr-pane" || {
  echo "the launcher never starts the dev-tab parker" >&2
  exit 1
}

echo "herdr-fresh-pane --daemon: ok"
