#!/usr/bin/env bash
# GUI fixture must never delete a caller's existing files or real Mash state.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
helper="$here/keybinding-gui-env.sh"
root="$(mktemp -d /tmp/mash-kb-qa.XXXXXX)"
trap 'rm -rf -- "$root"' EXIT
printf 'preserve\n' > "$root/sentinel"
if MASH_TERMINAL=/bin/true bash "$helper" native "$root" >/dev/null 2>&1; then
  echo 'FAIL: GUI fixture accepted existing root' >&2
  exit 1
fi
[ "$(cat "$root/sentinel")" = preserve ]
# These checks must refuse before touching the user's data.
for unsafe in "$HOME" "$HOME/.mash" /tmp/mash-kb-../mash-escape; do
  if MASH_TERMINAL=/bin/true bash "$helper" native "$unsafe" >/dev/null 2>&1; then
    echo "FAIL: GUI fixture accepted unsafe root $unsafe" >&2
    exit 1
  fi
done
printf 'PASS: GUI fixture refuses existing and live-data roots\n'
