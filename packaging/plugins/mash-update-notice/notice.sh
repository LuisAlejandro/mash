#!/usr/bin/env bash
# Draw the update notice, wait for a key, and close.
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
status="${MASH_UPDATE_STATUS:-}"
system="${MASH_UPDATE_SYSTEM:-}"

clear
case "$status" in
up-to-date)
  if [ "$system" = Linux ]; then
    printf '%s' "$(mash_say plugin.mash-update-notice.pane.up-to-date-linux \
      $'\n  No newer Mash version found in the current APT metadata.\n\n  If package lists may be old, run sudo apt update.   (any key closes)')"
  else
    printf '%s' "$(mash_say plugin.mash-update-notice.pane.up-to-date-macos \
      $'\n  Everything is up to date (Mash {version}).\n\n  (any key closes)' \
      "version=${installed:-unknown}")"
  fi
  ;;
updates-disabled)
  printf '\n  Updates are disabled in this build of Mash (%s).\n\n' "${installed:-unknown}"
  printf '  Official releases do not cover this architecture.\n'
  printf '  To update, rebuild Mash from source.   (any key closes)'
  ;;
restart-required)
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.restart-required \
    $'\n  Mash {installed} is running; Mash {candidate} is already installed.\n\n  Save work and restart Mash to use the installed version.\n  No download is needed.   (any key closes)' \
    "installed=${installed:-unknown}" "candidate=${candidate:-unknown}")"
  ;;
restored-previous)
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.previous-restored \
    $'\n  Mash {installed} is running again.\n\n  The update to {candidate} did not complete. Your workspace files were not rolled back.\n\n  (any key closes)' \
    "installed=${installed:-unknown}" "candidate=${candidate:-unknown}")"
  ;;
check-unavailable)
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.check-failed \
    $'\n  Could not check for updates right now.\n\n  Check your internet connection and try again.   (any key closes)')"
  ;;
apt-unavailable)
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.apt-failed \
    $'\n  No update information was found in APT.\n\n  Verify the Mash repository and run sudo apt update.   (any key closes)')"
  ;;
*)
  if [ -n "$candidate" ]; then
    printf '%s' "$(mash_say plugin.mash-update-notice.pane.available-linux \
      $'\n  Mash {candidate} is available (you have {installed}).\n\n  To upgrade, run:\n    sudo apt install --only-upgrade letsmash\n\n  Then restart Mash.   (any key closes)' \
      "candidate=$candidate" "installed=${installed:-an older version}")"
  fi
  ;;
esac

# A popup that exits at once would vanish before anyone read it.
IFS= read -rsn1 _ </dev/tty || true

herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
