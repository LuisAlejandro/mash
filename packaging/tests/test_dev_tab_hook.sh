#!/usr/bin/env bash
# Reproduce the "+" button leaving a tab with one pane stuck on "Starting the editor".
#
# Herdr's "+" runs its built-in new_tab action, which takes no configuration, so
# Mash reacts to tab.created with plugins/dev-tab/dev-tab.sh and delegates the
# layout to herdr-dev-tab-fill -- the same script cmd+t runs directly. cmd+t
# works and "+" did not, so the fault is on the hook's side of that call.
#
# The hook used to resolve the builder with `command -v` alone. When the PATH
# Herdr gives a plugin command does not carry Mash's bin directory, the lookup
# found nothing and the hook exited 0 without a word: a hook that declined and a
# hook that ran look identical from the outside, so the tab simply sat there with
# one pane and a "Starting the editor" line.
#
# This drives the real hook, in a staged bundle layout, against a throwaway Herdr
# server -- with the builder on PATH, and without it.
#
# Needs the pinned Herdr; CI runners do not have it, so it skips there.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

if ! command -v herdr >/dev/null 2>&1; then
	printf 'SKIP: herdr is not installed\n'
	exit 77
fi
herdr_bin="$(command -v herdr)"

root="$(mktemp -d)"
cleanup() {
	HERDR_SOCKET_PATH="$root/h.sock" herdr server stop >/dev/null 2>&1 || true
	rm -rf -- "$root"
}
trap cleanup EXIT

# The bundle shape the hook runs in: helpers in Resources/bin, plugins beside them.
res="$root/bundle"
mkdir -p "$res/bin" "$res/plugins/dev-tab" "$root/cfg" "$root/work"
cp "$repo/packaging/plugins/dev-tab/dev-tab.sh" "$res/plugins/dev-tab/dev-tab.sh"
cp "$repo/packaging/plugins/dev-tab/herdr-plugin.toml" "$res/plugins/dev-tab/herdr-plugin.toml"
# A stand-in layout builder: records that the hook reached it, then gives the tab
# a second pane so the test can tell "declined" from "delegated".
cat >"$res/bin/herdr-dev-tab-fill" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$DEV_TAB_FILL_LOG"
"${HERDR_BIN_PATH:-herdr}" pane split "$1" --direction right --ratio 0.6 --no-focus >/dev/null 2>&1 || true
EOF
chmod +x "$res/bin/herdr-dev-tab-fill"
hook="$res/plugins/dev-tab/dev-tab.sh"

unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH HERDR_CLIENT_SOCKET_PATH
export HERDR_SOCKET_PATH="$root/h.sock"
export HERDR_CONFIG_PATH="$root/config.toml" XDG_CONFIG_HOME="$root/cfg"
printf 'onboarding = false\n\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "/bin/sh"\n' \
	>"$HERDR_CONFIG_PATH"

(cd "$root/work" && "$herdr_bin" server >/dev/null 2>&1 &)
for _ in $(seq 1 60); do
	herdr workspace list >/dev/null 2>&1 && break
	sleep 0.1
done
herdr workspace list >/dev/null 2>&1 || {
	printf 'FAIL: the scratch herdr server did not start\n' >&2
	exit 1
}
herdr workspace create --cwd "$root/work" >/dev/null

pane_count() {
	herdr tab get "$1" 2>/dev/null |
		python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["tab"]["pane_count"])'
}

fail=0
run_case() {
	local label="$1" path="$2" plugin_root="$3" tab payload n
	tab="$(herdr tab create --cwd "$root/work" |
		python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')"
	sleep 1
	payload="$(python3 -c 'import json,sys
print(json.dumps({"event":"tab.created","data":{"tab":{"tab_id":sys.argv[1],"label":"2","pane_count":1}}}))' "$tab")"
	: >"$root/fill.log"
	env -u HERDR_ENV -u HERDR_PANE_ID \
		PATH="$path" ${plugin_root:+HERDR_PLUGIN_ROOT="$plugin_root"} \
		HERDR_BIN_PATH="$herdr_bin" HERDR_SOCKET_PATH="$HERDR_SOCKET_PATH" \
		HERDR_PLUGIN_EVENT_JSON="$payload" DEV_TAB_FILL_LOG="$root/fill.log" \
		bash "$hook"
	n="$(pane_count "$tab")"
	printf '  %-34s panes=%s builder-reached=%s\n' "$label" "$n" \
		"$([ -s "$root/fill.log" ] && echo yes || echo no)"
	[ "$n" = "2" ] || fail=1
}

echo "the hook must enrich a one-pane tab:"
run_case "builder on PATH" "$res/bin:/usr/bin:/bin" ""
run_case "builder NOT on PATH, plugin root set" "/usr/bin:/bin" "$res/plugins/dev-tab"

[ "$fail" = 0 ] || {
	printf 'FAIL: the dev-tab hook left a tab unenriched\n' >&2
	exit 1
}
printf 'PASS: the dev-tab hook enriches a one-pane tab\n'
