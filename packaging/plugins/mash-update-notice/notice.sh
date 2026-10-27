#!/usr/bin/env bash
# Draw the update notice, wait for a key, and close.
set -u

installed="${MASH_UPDATE_INSTALLED:-}"
candidate="${MASH_UPDATE_CANDIDATE:-}"

clear
if [ -n "$candidate" ]; then
  printf '\n  Mash %s is available (you have %s).\n\n' "$candidate" "${installed:-an older version}"
  printf '  To upgrade, run:\n    sudo apt install --only-upgrade letsmash\n\n'
  printf '  Then restart Mash.   (any key closes)'
fi

# A popup that exits at once would vanish before anyone read it.
IFS= read -rsn1 _ </dev/tty || true

herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
