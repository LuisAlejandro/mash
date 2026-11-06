#!/usr/bin/env bash
# The macOS update popup: announce, download, verify, confirm, hand off.
#
# Everything destructive lives in the helpers this calls. This script owns the
# conversation with the user and nothing else, so a failure here can only ever
# cost the user a popup.
set -u

# The Herdr server starts this pane, so its PATH, MASH_LANGUAGE and
# MASH_I18N_DIR belong to whatever launched the server. mash_messages_bind in
# lib.sh resolves this install's mash-t and catalogs, and mash_say prints the
# English fallback when a message cannot be found.
here="$(cd "$(dirname "$0")" && pwd)"
for mash_lib in "$here/../../bin/lib.sh" "$here/../../lib.sh"; do
  if [ -f "$mash_lib" ]; then
    # shellcheck disable=SC1090
    source "$mash_lib"
    break
  fi
done
if command -v mash_messages_bind >/dev/null 2>&1; then
  mash_messages_bind "${MASH_UPDATE_DATA:-${HOME:-}/.mash}"
else
  # No library at all: still print the English text, with placeholders filled.
  mash_say() {
    local text="$2" arg
    shift 2
    for arg in "$@"; do
      text="${text//"{${arg%%=*}}"/${arg#*=}}"
    done
    printf '%s' "$text"
  }
fi

installed="${MASH_UPDATE_INSTALLED:-}"
candidate="${MASH_UPDATE_CANDIDATE:-}"
can_apply="${MASH_UPDATE_CAN_APPLY:-0}"
app="${MASH_UPDATE_APP:-}"
data="${MASH_UPDATE_DATA:-${HOME:-}/.mash}"

# The helpers sit beside the herdr this pane was launched from.
bin="$(cd "$(dirname "$(command -v herdr)")" 2>/dev/null && pwd)"
verify="$bin/mash-update-verify"

close() {
  herdr plugin pane close "${HERDR_PANE_ID:-}" >/dev/null 2>&1 || true
  exit 0
}

clear
[ -n "$candidate" ] || close

# A bundle we cannot replace -- a read-only DMG mount, a dist tree -- still
# gets told, it just cannot be offered the one-key path.
if [ "$can_apply" != 1 ] || [ ! -x "$verify" ]; then
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.update-unavailable \
    $'\n  Mash {candidate} is available (you have {installed}).\n\n  Download it from:\n    {url}\n\n  (any key closes)' \
    "candidate=$candidate" "installed=${installed:-an older version}" \
    "url=https://github.com/LuisAlejandro/mash/releases/latest")"
  IFS= read -rsn1 _ </dev/tty || true
  close
fi

printf '%s' "$(mash_say plugin.mash-update-notice.pane.update-prompt \
  $'\n  Mash {candidate} is available (you have {installed}).\n\n  Press u to update now, or any other key to dismiss.\n  Updating quits Mash and reopens it on the new version.\n\n  > ' \
  "candidate=$candidate" "installed=${installed:-an older version}")"
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

printf '\n  %s' "$(mash_say helper.popup.dismiss '(any key closes)')"
IFS= read -rsn1 _ </dev/tty || true
close
