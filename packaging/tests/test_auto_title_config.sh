#!/bin/bash
# How Mash names a tab must survive a Mash upgrade, and stay the user's to change.
#
# Two things are easy to get wrong here, and both were:
#
#   The settings lived in lib.sh as HERDR_AUTO_TITLE_* environment variables.
#   Auto Title lets an environment variable win over config.env, so exporting
#   them meant no user could ever change how their tabs are named -- editing the
#   seeded file did nothing.
#
#   The file itself is seeded once and then belongs to whoever edits it. A later
#   Mash that seeds different values must move a file it wrote, and leave a file
#   the user wrote alone, or the fix never reaches the machines that need it.
#
# What the values are, and why, lives in the shipped file's own comments; this
# test pins that the file says them at all.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { # check MSG CMD... -- record a pass when CMD succeeds
  local msg="$1"
  shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

shipped="$root/packaging/defaults/herdr-auto-title/config.env"
check "the shipped config.env exists" test -f "$shipped"

# Every setting is stated once, as the plugin reads it: NAME=value, no quotes,
# no export. A quoted or exported form is silently not a setting.
for setting in \
  "HERDR_AUTO_TITLE_PREFER_AGENT=true" \
  "HERDR_AUTO_TITLE_AGENT_NAME=false" \
  "HERDR_AUTO_TITLE_BRANCH_MAX=0" \
  "HERDR_AUTO_TITLE_AGENT_STATUS=true"; do
  check "config.env sets $setting" grep -qxF "$setting" "$shipped"
done
if grep -qE '^[[:space:]]*export[[:space:]]+' "$shipped" ||
  grep -qE '^[[:space:]]*HERDR_AUTO_TITLE_[A-Z_]+="' "$shipped"; then
  nok "no setting is quoted or exported"
else
  ok "no setting is quoted or exported"
fi

# The environment must not shadow the file. mash_isolate is what a launch runs
# before the server starts, and it owns every HERDR_* variable it clears.
res="$tmp/res"
mkdir -p "$res/bin" "$res/defaults"
printf '9.9.9\n' >"$res/VERSION"
: >"$res/defaults/optional-programming.txt"
cp -R "$root/packaging/defaults/herdr-auto-title" "$res/defaults/herdr-auto-title"
for f in lib.sh launch-common.sh; do cp "$root/packaging/$f" "$res/bin/$f"; done
home="$tmp/home"
mkdir -p "$home/.mash/run" "$home/.mash/bin"
isolated="$(env -i HOME="$home" PATH="/usr/bin:/bin" \
  MASH_BIN="$res/bin:$home/.mash/bin" \
  HERDR_AUTO_TITLE_AGENT_NAME=true \
  HERDR_AUTO_TITLE_PREFER_AGENT=false \
  bash -c 'source "$1"; mash_isolate "$2"; env' _ "$res/bin/lib.sh" "$home")"
for name in HERDR_AUTO_TITLE_PREFER_AGENT HERDR_AUTO_TITLE_AGENT_NAME \
  HERDR_AUTO_TITLE_BRANCH_MAX HERDR_AUTO_TITLE_AGENT_STATUS; do
  check "mash_isolate leaves $name to config.env" \
    bash -c '! printf "%s\n" "$1" | grep -qx "$2=.*"' _ "$isolated" "$name"
done

# --- a fresh install seeds the file ----------------------------------------
. "$root/packaging/launch-common.sh"
d="$tmp/data"
mkdir -p "$d"
mash_seed_missing "$res/defaults/herdr-auto-title" "$d/config/herdr-auto-title" 2>/dev/null ||
  cp -R "$res/defaults/herdr-auto-title" "$d/config/herdr-auto-title"
live="$d/config/herdr-auto-title/config.env"
check "a fresh install seeds config.env" test -f "$live"
check "the seeded file carries the preferences" \
  grep -qxF "HERDR_AUTO_TITLE_PREFER_AGENT=true" "$live"

# --- an upgrade: Mash moves a file it wrote --------------------------------
# The shape of the previous release: Mash shipped AGENT_NAME=true back then and
# recorded the checksum of what it wrote. The new bundle seeds false.
d2="$tmp/upgraded"
mkdir -p "$d2/config/herdr-auto-title" "$d2/local/state"
cp "$root/packaging/helpers/mash-seed-sync" "$res/bin/mash-seed-sync"
printf 'HERDR_AUTO_TITLE_AGENT_NAME=true\n' >"$d2/config/herdr-auto-title/config.env"
python3 - "$d2" <<'PY'
import hashlib, json, pathlib, sys
d = pathlib.Path(sys.argv[1])
f = d / "config/herdr-auto-title/config.env"
json.dump({"version": "0.4.1",
           "selection": {"programming": True, "design": False},
           "resource_root": "a-previous-bundle",
           "files": {str(f.relative_to(d)): hashlib.sha256(f.read_bytes()).hexdigest()}},
          open(d / "local/state/seeded.json", "w"))
PY
"$res/bin/mash-seed-sync" "$res" "$d2" >/dev/null 2>&1 || true
check "an upgrade replaces the value Mash shipped last time" \
  grep -qxF "HERDR_AUTO_TITLE_AGENT_NAME=false" "$d2/config/herdr-auto-title/config.env"

# --- a file the user edited keeps their text -------------------------------
# Provenance is the contract: Mash updates a file while it still matches what it
# wrote. Someone who changed their tab naming owns the file, and their line stays.
printf 'HERDR_AUTO_TITLE_AGENT_NAME=true\n' >"$d2/config/herdr-auto-title/config.env"
printf '# my tweak\n' >>"$d2/config/herdr-auto-title/config.env"
"$res/bin/mash-seed-sync" "$res" "$d2" >/dev/null 2>&1 || true
check "a user-edited config.env is left alone" \
  grep -qxF "HERDR_AUTO_TITLE_AGENT_NAME=true" "$d2/config/herdr-auto-title/config.env"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
