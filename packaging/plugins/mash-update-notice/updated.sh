#!/usr/bin/env bash
# One-time success confirmation in the first window of the new Mash.
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

version="${MASH_UPDATE_INSTALLED:-}"
clear
if [ -n "$version" ]; then
  printf '%s' "$(mash_say plugin.mash-update-notice.pane.updated \
    $'\n  Mash {version} is installed and running.\n\n  Your workspaces and configuration remain in ~/.mash.\n\n  (any key closes)' \
    "version=$version")"
else
  printf '\n  %s' "$(mash_say helper.popup.dismiss '(any key closes)')"
fi
IFS= read -rsn1 _ </dev/tty || true
herdr plugin pane close "${HERDR_PANE_ID:-}" >/dev/null 2>&1 || true
