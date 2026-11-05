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
    printf '%s' "$(mash-t plugin.mash-update-notice.pane.up-to-date-linux)"
  else
    printf '%s' "$(mash-t plugin.mash-update-notice.pane.up-to-date-macos "version=${installed:-unknown}")"
  fi
  ;;
restart-required)
  printf '%s' "$(mash-t plugin.mash-update-notice.pane.restart-required "installed=${installed:-unknown}" "candidate=${candidate:-unknown}")"
  ;;
restored-previous)
  printf '%s' "$(mash-t plugin.mash-update-notice.pane.previous-restored "installed=${installed:-unknown}" "candidate=${candidate:-unknown}")"
  ;;
check-unavailable)
  printf '%s' "$(mash-t plugin.mash-update-notice.pane.check-failed)"
  ;;
apt-unavailable)
  printf '%s' "$(mash-t plugin.mash-update-notice.pane.apt-failed)"
  ;;
*)
  if [ -n "$candidate" ]; then
    printf '%s' "$(mash-t plugin.mash-update-notice.pane.available-linux "candidate=$candidate" "installed=${installed:-an older version}")"
  fi
  ;;
esac

# A popup that exits at once would vanish before anyone read it.
IFS= read -rsn1 _ </dev/tty || true

herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
