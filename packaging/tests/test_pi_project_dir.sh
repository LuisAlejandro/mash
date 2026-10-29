#!/usr/bin/env bash
# Mash reads per-project Pi configuration from .mash, not .pi.
#
# The whole mechanism is one key in Pi's own package.json
# (piConfig.configDir), which Pi reads at startup as CONFIG_DIR_NAME and then
# joins with the cwd for settings.json, mcp.json, extensions/, skills/,
# prompts/, themes/ and the system-prompt files. A Pi bump that renames the key
# or changes how it is read would silently restore .pi everywhere, so this
# suite checks the real bundled Pi rather than the staging function alone.
#
# Runs against the installed bundle when there is one; otherwise it stages a
# fake package.json so the staging contract is still covered on a machine that
# has never built Mash.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../build-common.sh
source "$root/packaging/build-common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() {
	local msg="$1"
	shift
	if "$@"; then ok "$msg"; else nok "$msg"; fi
}

pi_rel="node/lib/node_modules/@earendil-works/pi-coding-agent"

# mash_set_pi_project_dir deliberately verifies its own work by importing Pi's
# config module, so every check below needs a Node to run it. Skip rather than
# fail when the host has none: a missing interpreter is an absent tool, not a
# broken contract, and the build calls this function with the Node it just
# staged. The suites that must fail loudly on a missing tool are the ones whose
# subject IS that tool.
# `command -v` is not enough: it answers for a node that cannot execute at all
# (a binary for the wrong architecture, a broken symlink), and the failure then
# surfaces as the staging function reporting an empty project dir rather than
# as the missing tool it is. Run it.
if ! node --version >/dev/null 2>&1; then
	printf 'skip - no working node; the project-dir contract is unverified here\n'
	exit 0
fi

# --- the staging function writes the key and keeps the rest of the manifest --
res="$tmp/res"
mkdir -p "$res/$pi_rel/dist" "$res/node/bin"
cat >"$res/$pi_rel/package.json" <<'EOF'
{
  "name": "@earendil-works/pi-coding-agent",
  "version": "1.1.0",
  "piConfig": {
    "configDir": ".pi"
  }
}
EOF
# A stand-in for the real config.js: the staging function verifies its answer
# through Pi's own module, so the check needs something to import.
cat >"$res/$pi_rel/dist/config.js" <<'EOF'
import { createRequire } from "node:module";
const pkg = createRequire(import.meta.url)("../package.json");
export const CONFIG_DIR_NAME = pkg.piConfig?.configDir || ".pi";
EOF
printf '#!/bin/sh\nexec node "$@"\n' >"$res/node/bin/node"
chmod 755 "$res/node/bin/node"

mash_set_pi_project_dir "$res" || {
	echo "the staging function failed" >&2
	exit 1
}
check "configDir is rewritten to .mash" \
	grep -Fq '".mash"' "$res/$pi_rel/package.json"
check "the rest of the manifest survives" \
	grep -Fq '"@earendil-works/pi-coding-agent"' "$res/$pi_rel/package.json"
check "the manifest stays valid JSON" \
	python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$res/$pi_rel/package.json"

# Running it twice must not append a second key or corrupt the file.
mash_set_pi_project_dir "$res" >/dev/null
check "staging is idempotent" \
	python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["piConfig"]["configDir"]==".mash" else 1)' \
	"$res/$pi_rel/package.json"

# --- a Pi that no longer honors the key must fail the build, not ship --------
broken="$tmp/broken"
mkdir -p "$broken/$pi_rel/dist" "$broken/node/bin"
cp "$res/node/bin/node" "$broken/node/bin/node"
printf '{"name":"x"}\n' >"$broken/$pi_rel/package.json"
printf 'export const CONFIG_DIR_NAME = ".pi";\n' >"$broken/$pi_rel/dist/config.js"
if mash_set_pi_project_dir "$broken" 2>/dev/null; then
	nok "a Pi that ignores configDir is rejected"
else
	ok "a Pi that ignores configDir is rejected"
fi

# --- the installed bundle, reported but never failed -------------------------
# A Pi bump that breaks the key is caught at BUILD time: mash_set_pi_project_dir
# verifies the staged tree and fails the build. The installed app is the user's
# live data, not a fixture this suite owns, and it is legitimately stale between
# a source change and the next reinstall -- so this only reports.
# packaging/tests/verify-installed.sh is the opt-in drift check.
installed="${MASH_APP:-/Applications/Mash.app}/Contents/Resources"
if [ -f "$installed/$pi_rel/dist/config.js" ]; then
	reported="$("$installed/node/bin/node" --input-type=module -e \
		'const m = await import(process.argv[1]); process.stdout.write(m.CONFIG_DIR_NAME ?? "")' \
		"$installed/$pi_rel/dist/config.js" 2>/dev/null || true)"
	if [ "$reported" = ".mash" ]; then
		ok "the installed Pi resolves .mash"
	else
		printf 'note - the installed Pi still resolves %s; rebuild and reinstall to apply\n' \
			"${reported:-<unknown>}"
	fi
else
	printf 'skip - no installed bundle at %s\n' "$installed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
