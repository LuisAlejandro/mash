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
esac
exit 0
SH
chmod +x "$tmp/bin/herdr"

# A fake fresh: records how it was invoked, then exits successfully.
cat >"$tmp/bin/fresh" <<'SH'
#!/bin/sh
printf 'fresh %s\n' "$*" >>"$FAKE_FRESH_LOG"
SH
chmod +x "$tmp/bin/fresh"

run() {
  : >"$tmp/herdr.log"
  : >"$tmp/fresh.log"
  PATH="$tmp/bin:$PATH" HERDR_BIN_PATH="$tmp/bin/herdr" \
    FAKE_HERDR_LOG="$tmp/herdr.log" FAKE_FRESH_LOG="$tmp/fresh.log" \
    "$tmp/bin/herdr-fresh-pane" "$@"
}

# --- a dev tab attaches to the shared daemon --------------------------------
run --daemon .
grep -qx 'fresh -a' "$tmp/fresh.log" || {
  echo "a dev tab did not attach to the daemon: $(cat "$tmp/fresh.log")" >&2
  exit 1
}
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

# --- panes that are not dev tabs must not --------------------------------
for file in packaging/helpers/telescope-files \
  packaging/defaults/plugins/fullerzz.sesh/config.toml; do
  grep -q 'herdr-fresh-pane --daemon' "$root/$file" && {
    echo "$file is not a dev tab but would attach to the shared daemon" >&2
    exit 1
  }
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
