#!/bin/bash
# The data directory must not be readable by another account.
#
# ~/.mash holds agent conversation transcripts, logs and credentials, and the
# files inside it are written by tools Mash does not own -- Pi writes session
# transcripts mode 0644, Fresh writes one log per editor. Tightening each file is
# not possible; 0700 on the root is enough, because reaching any descendant
# requires +x on it. The failure this pins: the launcher used `mkdir -p`, which
# inherits the umask (0755), so every transcript was world-readable.
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

# shellcheck source=../../packaging/launch-common.sh
. "$root/packaging/launch-common.sh"

# Shared with the launcher so the two cannot disagree about how to read a mode.
# Do not inline a `stat -f ... || stat -c ...` fallback here: GNU stat treats
# -f as --file-system and prints a filesystem report on stdout before failing,
# so the fallback's output lands after it and no comparison can match.
mode() { mash_file_mode "$1"; }

# --- a fresh directory is created 0700 --------------------------------------
fresh="$tmp/fresh"
( umask 022; mash_protect_data_dir "$fresh" )
check "a new data directory is 0700" test "$(mode "$fresh")" = "700"

# --- an existing 0755 directory is tightened --------------------------------
# This is the shape every install made before the fix is in.
legacy="$tmp/legacy"
mkdir -p "$legacy/sessions"
chmod 755 "$legacy" "$legacy/sessions"
printf 'transcript\n' >"$legacy/sessions/one.jsonl"
chmod 644 "$legacy/sessions/one.jsonl"
check "the fixture starts world-traversable" test "$(mode "$legacy")" = "755"
mash_protect_data_dir "$legacy"
check "an existing 0755 data directory is tightened to 0700" \
  test "$(mode "$legacy")" = "700"

# --- a file inside is still unreachable, whatever its own mode --------------
# The point of one chmod on the root: 0644 transcripts stop mattering.
check "contents keep their mode (0700 on the root is what gates them)" \
  test "$(mode "$legacy/sessions/one.jsonl")" = "644"
check "so a second account cannot read the transcript through the root" \
  test "$(mode "$legacy")" = "700"

# --- idempotent, and it does not fail when chmod cannot succeed ------------
mash_protect_data_dir "$legacy"
check "running it again is harmless" test "$(mode "$legacy")" = "700"
check "a path it cannot create returns non-zero instead of aborting the caller" \
  bash -c '. "$1"; ! mash_protect_data_dir /proc/nope/nope' _ "$root/packaging/launch-common.sh"
check "and it does not exit the caller's shell" \
  bash -c '. "$1"; mash_protect_data_dir /proc/nope/nope || true; echo alive' \
  _ "$root/packaging/launch-common.sh"

# --- the launchers create the root through the protected helper ------------
for f in packaging/mash packaging/linux/launcher; do
  check "$f no longer creates the root with a bare mkdir" \
    bash -c '! grep -qE "^mkdir -p \"\\\$d\"$" "$1"' _ "$root/$f"
  check "$f goes through mash_protect_data_dir" \
    grep -q 'mash_protect_data_dir "\$d"' "$root/$f"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
