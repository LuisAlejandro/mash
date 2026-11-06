#!/usr/bin/env bash
# Draw the update notice, wait for a key, and close.
set -u

installed="${MASH_UPDATE_INSTALLED:-}"
candidate="${MASH_UPDATE_CANDIDATE:-}"
status="${MASH_UPDATE_STATUS:-}"
system="${MASH_UPDATE_SYSTEM:-}"

clear
case "$status" in
up-to-date)
  if [ "$system" = Linux ]; then
    printf '\n  No newer Mash version found in the current APT metadata.\n\n'
    printf '  If package lists may be old, run sudo apt update.   (any key closes)'
  else
    printf '\n  Everything is up to date (Mash %s).\n\n' "${installed:-unknown}"
    printf '  (any key closes)'
  fi
  ;;
updates-disabled)
  printf '\n  Updates are disabled in this build of Mash (%s).\n\n' "${installed:-unknown}"
  printf '  Official releases do not cover this architecture.\n'
  printf '  To update, rebuild Mash from source.   (any key closes)'
  ;;
restart-required)
  printf '\n  Mash %s is running; Mash %s is already installed.\n\n' "${installed:-unknown}" "${candidate:-unknown}"
  printf '  Save work and restart Mash to use the installed version.\n'
  printf '  No download is needed.   (any key closes)'
  ;;
restored-previous)
  printf '\n  Mash %s is running again.\n\n' "${installed:-unknown}"
  printf '  The update to %s did not complete. Your workspace files were not rolled back.\n\n' "${candidate:-unknown}"
  printf '  (any key closes)'
  ;;
check-unavailable)
  printf '\n  Could not check for updates right now.\n\n'
  printf '  Check your internet connection and try again.   (any key closes)'
  ;;
apt-unavailable)
  printf '\n  No update information was found in APT.\n\n'
  printf '  Verify the Mash repository and run sudo apt update.   (any key closes)'
  ;;
*)
  if [ -n "$candidate" ]; then
    printf '\n  Mash %s is available (you have %s).\n\n' "$candidate" "${installed:-an older version}"
    printf '  To upgrade, run:\n    sudo apt install --only-upgrade letsmash\n\n'
    printf '  Then restart Mash.   (any key closes)'
  fi
  ;;
esac

# A popup that exits at once would vanish before anyone read it.
IFS= read -rsn1 _ </dev/tty || true

herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
