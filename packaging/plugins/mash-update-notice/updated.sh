#!/usr/bin/env bash
# One-time success confirmation in the first window of the new Mash.
set -u
version="${MASH_UPDATE_INSTALLED:-}"
clear
if [ -n "$version" ]; then
  printf '\n  Mash %s is installed and running.\n\n' "$version"
  printf '  Your workspaces and configuration remain in ~/.mash.\n\n'
fi
printf '  (any key closes)'
IFS= read -rsn1 _ </dev/tty || true
herdr plugin pane close "${HERDR_PANE_ID:-}" >/dev/null 2>&1 || true
