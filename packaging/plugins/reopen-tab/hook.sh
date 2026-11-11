#!/usr/bin/env bash
# Forward a reopen-tab event hook to the helper that owns the logic.
#
# Herdr runs a manifest command with the plugin's root as its working directory
# and with the server's own environment, which is not guaranteed to carry the
# bundle's bin directory on PATH -- Mash's Herdr config prefixes its own
# `[[keys.command]]` bodies with PATH="${HERDR_BIN_PATH%/*}:$PATH" for exactly
# that reason. Resolve the helper the same way here, falling back to PATH when
# HERDR_BIN_PATH is unset (a dev Herdr started outside Mash).
set -eu

case "${1:-}" in
capture | closed) ;;
*)
	printf 'usage: %s capture|closed\n' "$0" >&2
	exit 64
	;;
esac

bin="${HERDR_BIN_PATH:+$(dirname "$HERDR_BIN_PATH")}"
helper=""
if [ -n "$bin" ] && [ -x "$bin/herdr-tabs" ]; then
	helper="$bin/herdr-tabs"
elif helper="$(command -v herdr-tabs)"; then
	:
else
	# No helper means no snapshot; failing loudly would only add noise to every
	# tab focus, so report once and let the plugin carry on.
	printf 'reopen-tab: herdr-tabs not found\n' >&2
	exit 1
fi

exec "$helper" "$1"
