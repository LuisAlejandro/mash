#!/usr/bin/env bash
# One-time success confirmation in the first window of the new Mash.
set -u
version="${MASH_UPDATE_INSTALLED:-}"
clear
if [ -n "$version" ]; then
  printf '%s' "$(mash-t plugin.mash-update-notice.pane.updated "version=$version")"
else
  printf '\n  %s' "$(mash-t helper.popup.dismiss)"
fi
IFS= read -rsn1 _ </dev/tty || true
herdr plugin pane close "${HERDR_PANE_ID:-}" >/dev/null 2>&1 || true
