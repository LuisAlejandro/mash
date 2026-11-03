#!/bin/bash
# macOS update state and cleanup must never depend on the user's real app/job.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
  echo 'SKIP: macOS property lists and process identity'
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/local/state" "$tmp/Mash.app/Contents" "$tmp/mash-update-ABCDEF"
cp "$root/packaging/helpers/mash-update-common" "$tmp/bin/"
xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
  "$root/packaging/helpers/mash-update-processes.c" -o "$tmp/bin/mash-update-processes"
# shellcheck source=../helpers/mash-update-common
source "$tmp/bin/mash-update-common"
mash_update_init "$tmp/home"
mash_update_begin "$tmp/Mash.app" 9.9.9 9.9.8 "$tmp/mash-update-ABCDEF"
id="$MU_ID"
[ "$(mash_update_read phase)" = preparing ]
mash_update_active
# A concurrent request must not remove the active owner's lock or state.
if (mash_update_begin "$tmp/Mash.app" 9.9.9 9.9.8 "$tmp/mash-update-ABCDEF"); then
  echo 'FAIL: a live attempt was replaced' >&2; exit 1
fi
[ "$(mash_update_read id)" = "$id" ]
mash_update_write phase quiescing
[ "$(mash_update_read phase)" = quiescing ]
mash_update_finish cancelled
[ ! -d "$MU_LOCK" ]
# Cleanup from an older attempt cannot clear a newer one's ownership.
mash_update_begin "$tmp/Mash.app" 9.9.9 9.9.8 "$tmp/mash-update-ABCDEF"
new="$MU_ID"
MU_ID="$id"
if mash_update_finish failed-before-swap; then
  echo 'FAIL: old cleanup changed the current attempt' >&2; exit 1
fi
[ "$(mash_update_read id)" = "$new" ]
MU_ID="$new"
mash_update_write owner_start invalid
! mash_update_active
mash_update_finish failed-before-swap
# An unsafe state path is rejected before writing through it.
rm -f "$MU_TX"
ln -s "$tmp/do-not-write" "$MU_TX"
! mash_update_begin "$tmp/Mash.app" 9.9.9 9.9.8 "$tmp/mash-update-ABCDEF"
[ ! -e "$tmp/do-not-write" ]
# The existing handoff fixture must never share a production label or app path.
! grep -q '^label="app.mash.update"$' "$root/packaging/tests/test_mash_update_handoff.sh"
! grep -q '/Applications/Mash.app' "$root/packaging/tests/test_mash_update_handoff.sh"
echo 'PASS: exclusive update state, stale ownership, safe cleanup and fixture isolation'
