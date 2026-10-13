#!/usr/bin/env bash
set -euo pipefail

helper="${1:-$(cd "$(dirname "$0")/.." && pwd)/telescope-files}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/bin/telescope" <<'EOF'
#!/bin/sh
printf 'id\t%s/file.txt\tfile.txt\n' "$HERDR_ACTIVE_PANE_CWD"
EOF
cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
: >"$FZF_MARKER"
EOF
chmod +x "$tmp/bin/"*
touch "$tmp/file.txt"

output="$(env PATH=/usr/bin:/bin \
	HERDR_BIN_PATH="$tmp/bin/herdr" \
	TELESCOPE_BIN="$tmp/bin/telescope" \
	HERDR_ACTIVE_PANE_CWD="$tmp" \
	FZF_MARKER="$tmp/fzf-ran" \
	bash "$helper" 2>&1)" || {
	printf '%s\n' "$output" >&2
	exit 1
}
[ -f "$tmp/fzf-ran" ] || {
	printf 'fzf was not found through Herdr PATH:\n%s\n' "$output" >&2
	exit 1
}

# Without TELESCOPE_BIN the binary has to be found the way Herdr resolves a
# plugin command: from the plugin root beside the running Herdr. Nothing puts
# herdr-telescope on PATH, so this is the case cmd+p actually hits.
mkdir -p "$tmp/app/bin" "$tmp/app/plugins/telescope/bin"
cat >"$tmp/app/bin/herdr" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmp/app/bin/fzf" <<'EOF'
#!/bin/sh
: >"$FZF_MARKER"
EOF
cat >"$tmp/app/plugins/telescope/bin/herdr-telescope" <<'EOF'
#!/bin/sh
: >"$TELESCOPE_MARKER"
printf 'id	%s/file.txt	file.txt\n' "$HERDR_ACTIVE_PANE_CWD"
EOF
chmod +x "$tmp/app/bin/"* "$tmp/app/plugins/telescope/bin/herdr-telescope"

output="$(env PATH=/usr/bin:/bin \
	HERDR_BIN_PATH="$tmp/app/bin/herdr" \
	HERDR_ACTIVE_PANE_CWD="$tmp" \
	FZF_MARKER="$tmp/fzf-linked-ran" \
	TELESCOPE_MARKER="$tmp/telescope-linked-ran" \
	bash "$helper" 2>&1)" || {
	printf '%s\n' "$output" >&2
	exit 1
}
[ -f "$tmp/telescope-linked-ran" ] || {
	printf 'linked-checkout telescope binary was not used:\n%s\n' "$output" >&2
	exit 1
}
[ -f "$tmp/fzf-linked-ran" ] || {
	printf 'fzf was not found for the linked-checkout case:\n%s\n' "$output" >&2
	exit 1
}
