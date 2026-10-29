#!/usr/bin/env bash
# Compare the installed Mash with this source tree, file by file.
#
# Why this exists: the bundle can be replaced by an older build (a reinstall, a
# drag from dist/), and the launcher re-copies Resources/bin into ~/.mash/bin on
# every open. A fix applied only to the working tree, or lost when the bundle was
# replaced, is therefore invisible until something misbehaves. That happened to
# mash-shell: its `mash_isolate "$home" pane` argument was lost, so Mash's panes
# stopped reporting their session to Herdr and stopped surviving a server
# restart. This script makes that class of drift a one-command check.
#
#   packaging/tests/verify-installed.sh [path/to/Mash.app]
#
# Exit 0 = nothing functional is out of sync. Whitespace-only differences (the
# repo is reindented from time to time) are reported but do not fail.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:-/Applications/Mash.app}"
res="$app/Contents/Resources"
home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$home" ] || home="$HOME"

if [ ! -d "$res" ]; then
	printf 'not a Mash bundle: %s\n' "$app" >&2
	exit 2
fi

functional=0
cosmetic=0

compare() {
	local src="$1" dest="$2" label="$3"
	if [ ! -e "$dest" ]; then
		printf 'MISSING   %s\n' "$label"
		functional=$((functional + 1))
		return
	fi
	if cmp -s "$src" "$dest"; then
		return
	fi
	if diff -w -B -q "$src" "$dest" >/dev/null 2>&1; then
		printf 'cosmetic  %s (whitespace only)\n' "$label"
		cosmetic=$((cosmetic + 1))
		return
	fi
	printf 'FUNCTIONAL DIFF  %s\n' "$label"
	functional=$((functional + 1))
}

echo "=== bundle: $app"
echo "--- entry points and shared library"
compare "$root/packaging/lib.sh" "$res/bin/lib.sh" "Resources/bin/lib.sh"
compare "$root/packaging/launch-common.sh" "$res/bin/launch-common.sh" "Resources/bin/launch-common.sh"
compare "$root/packaging/mash-shell" "$res/bin/mash-shell" "Resources/bin/mash-shell"
compare "$root/packaging/herdr-pane" "$res/bin/herdr-pane" "Resources/bin/herdr-pane"
compare "$root/packaging/mash" "$app/Contents/MacOS/mash" "Contents/MacOS/mash"

echo "--- helpers (every file build.sh ships)"
for src in "$root"/packaging/helpers/*; do
	[ -f "$src" ] || continue
	compare "$src" "$res/bin/$(basename "$src")" "Resources/bin/$(basename "$src")"
done

echo "--- carried defaults"
while IFS= read -r src; do
	rel="${src#"$root"/packaging/defaults/}"
	compare "$src" "$res/defaults/$rel" "Resources/defaults/$rel"
done < <(find "$root/packaging/defaults" -type f)

echo "--- live copies the launcher re-copies from the bundle"
compare "$root/packaging/lib.sh" "$home/.mash/bin/lib.sh" "~/.mash/bin/lib.sh"
compare "$root/packaging/mash-shell" "$home/.mash/bin/mash-shell" "~/.mash/bin/mash-shell"

echo "--- Pi project configuration directory"
# Mash reads per-project Pi config from .mash, written into the bundled Pi's
# package.json at build time (mash_set_pi_project_dir). A bundle built before
# that change, or a Pi bump that dropped the key, silently falls back to .pi
# and every project's .mash/settings.json, skills and prompts stop loading.
pi_config="$res/node/lib/node_modules/@earendil-works/pi-coding-agent/dist/config.js"
if [ -f "$pi_config" ]; then
	project_dir="$("$res/node/bin/node" --input-type=module -e \
		'const m = await import(process.argv[1]); process.stdout.write(m.CONFIG_DIR_NAME ?? "")' \
		"$pi_config" 2>/dev/null || true)"
	if [ "$project_dir" = ".mash" ]; then
		printf 'resolves  project config from .mash\n'
	else
		printf 'FUNCTIONAL DIFF  bundled Pi resolves project config from %s, not .mash\n' \
			"${project_dir:-<unknown>}"
		functional=$((functional + 1))
	fi
else
	printf 'MISSING   %s\n' "${pi_config#"$app"/}"
	functional=$((functional + 1))
fi

echo "--- code signature"
if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
	printf 'sealed    %s\n' "$app"
else
	printf 'SEAL BROKEN  %s -- the bundle grew files after signing\n' "$app"
	codesign --verify --deep --strict "$app" 2>&1 | sed -n '2,6p'
	functional=$((functional + 1))
fi

echo
printf 'functional drift: %d   cosmetic: %d\n' "$functional" "$cosmetic"
[ "$functional" -eq 0 ] || exit 1
