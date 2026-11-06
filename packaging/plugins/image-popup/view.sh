#!/usr/bin/env bash
# Draw $IMAGE_POPUP_FILE at the popup's size, then wait for a key and close.
#
# `viu` over `chafa` or `timg` on purpose: those two draw coloured block
# characters, which is the same illegible approximation the editor's hex dump
# is not. `viu` detects that the terminal speaks the Kitty graphics protocol
# and emits real pixels. Neither Herdr nor the editor is involved in that.
#
# The pane is sized with `tput` rather than a fixed width, so the image fills
# the popup and keeps its aspect ratio.
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
	mash_messages_bind "${HOME:-}/.mash"
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

f="${IMAGE_POPUP_FILE:-}"

# A popup pane is a terminal pane; without a tty there is nothing to draw to.
clear

if [ -z "$f" ] || [ ! -r "$f" ]; then
	printf '%s\n' "$(mash_say plugin.image-popup.no-image 'No image to show: {file}' "file=${f:-<none>}")"
elif ! command -v viu >/dev/null 2>&1; then
	printf '%s\n' "$(mash_say plugin.image-popup.viu-missing 'viu is not installed. Install it with: brew install viu')"
	printf '%s\n' "$(mash_say plugin.image-popup.source-file '(the image itself is at {file})' "file=$f")"
else
	cols="$(tput cols)"
	rows="$(tput lines)"
	# Two rows are kept for the filename line and the closing hint.
	viu -w "$cols" -h "$((rows > 4 ? rows - 3 : rows))" "$f"
	printf '\n%s   %s' "$(basename "$f")" "$(mash_say helper.popup.dismiss '(any key closes)')"
fi

# Block until the user dismisses. A popup that exits immediately would be gone
# before anyone saw it.
IFS= read -rsn1 _ </dev/tty || true

# Best-effort: `plugin pane close` is how a plugin-owned pane is dismissed, and
# HERDR_PANE_ID is set by Herdr for exactly this. If it is unavailable the pane
# simply stays until the user closes it.
herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
