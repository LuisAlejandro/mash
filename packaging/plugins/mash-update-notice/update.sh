#!/usr/bin/env bash
# The macOS update popup: announce, download, verify, confirm, hand off.
#
# Everything destructive lives in the helpers this calls. This script owns the
# conversation with the user and nothing else, so a failure here can only ever
# cost the user a popup.
set -u

installed="${MASH_UPDATE_INSTALLED:-}"
candidate="${MASH_UPDATE_CANDIDATE:-}"
can_apply="${MASH_UPDATE_CAN_APPLY:-0}"
app="${MASH_UPDATE_APP:-}"
data="${MASH_UPDATE_DATA:-$HOME/.mash}"

# The helpers sit beside the herdr this pane was launched from.
bin="$(cd "$(dirname "$(command -v herdr)")" 2>/dev/null && pwd)"
verify="$bin/mash-update-verify"

close() {
  herdr plugin pane close "${HERDR_PANE_ID:-}" >/dev/null 2>&1 || true
  exit 0
}

clear
[ -n "$candidate" ] || close

printf '\n  Mash %s is available (you have %s).\n\n' \
  "$candidate" "${installed:-an older version}"

# A bundle we cannot replace -- a read-only DMG mount, a dist tree -- still
# gets told, it just cannot be offered the one-key path.
if [ "$can_apply" != 1 ] || [ ! -x "$verify" ]; then
  printf '  Download it from:\n    https://github.com/LuisAlejandro/mash/releases/latest\n\n'
  printf '  (any key closes)'
  IFS= read -rsn1 _ </dev/tty || true
  close
fi

printf '  Press u to update now, or any other key to dismiss.\n'
printf '  Updating quits Mash and reopens it on the new version.\n\n'
printf '  > '
IFS= read -rsn1 key </dev/tty || close
case "$key" in
u | U) ;;
*) close ;;
esac

# From here the helper narrates: it downloads, verifies, counts the windows
# that will close, asks for the confirmation and starts the swap. It owns those
# steps because every one of them has cleanup this pane cannot do after it
# closes.
printf '\n\n'
"$verify" "$app" "$candidate" "$installed" "$data" </dev/tty

printf '\n  (any key closes)'
IFS= read -rsn1 _ </dev/tty || true
close
