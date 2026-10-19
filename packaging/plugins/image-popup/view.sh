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

f="${IMAGE_POPUP_FILE:-}"

# A popup pane is a terminal pane; without a tty there is nothing to draw to.
clear

if [ -z "$f" ] || [ ! -r "$f" ]; then
	printf 'No image to show: %s\n' "${f:-<none>}"
elif ! command -v viu >/dev/null 2>&1; then
	printf 'viu is not installed. Install it with: brew install viu\n'
	printf '(the image itself is at %s)\n' "$f"
else
	cols="$(tput cols)"
	rows="$(tput lines)"
	# Two rows are kept for the filename line and the closing hint.
	viu -w "$cols" -h "$((rows > 4 ? rows - 3 : rows))" "$f"
	printf '\n%s   (any key closes)' "$(basename "$f")"
fi

# Block until the user dismisses. A popup that exits immediately would be gone
# before anyone saw it.
IFS= read -rsn1 _ </dev/tty || true

# Best-effort: `plugin pane close` is how a plugin-owned pane is dismissed, and
# HERDR_PANE_ID is set by Herdr for exactly this. If it is unavailable the pane
# simply stays until the user closes it.
herdr plugin pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
