#!/usr/bin/env bash
# herdr-annotate-paste must point annotate's paste-archive at the tab's real
# agent pane, never at the fresh pane Mash reports as an agent named "fresh".
set -euo pipefail

helper="${1:-$(cd "$(dirname "$0")/.." && pwd)/herdr-annotate-paste}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/plugin/lite" "$tmp/plugin/bin"

# Fake annotate plugin whose binary records the context it was handed.
cat >"$tmp/plugin/bin/herdr-annotate.exe" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >"$TMP/argv"
printf '%s\n' "$HERDR_PLUGIN_CONTEXT_JSON" >"$TMP/context"
printf '%s\n' "$HERDR_PLUGIN_STATE_DIR" >"$TMP/state"
STUB
chmod 755 "$tmp/plugin/bin/herdr-annotate.exe"

# p1 is Mash's fresh pseudo-agent; p2 is the real pi agent in the same tab.
cat >"$tmp/bin/herdr" <<'STUB'
#!/bin/sh
fresh='{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","cwd":"/dir/fresh","agent":"fresh"}'
pi='{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","cwd":"/dir/pi","agent":"pi"}'
case "$1 $2" in
"pane list")
	if [ "${NO_AGENT:-}" = 1 ]; then
		printf '{"result":{"panes":[%s]}}' "$fresh"
	else
		printf '{"result":{"panes":[%s,%s]}}' "$fresh" "$pi"
	fi
	;;
"pane get")
	case "$3" in
	w1:p1) printf '{"result":{"pane":%s}}' "$fresh" ;;
	w1:p2) printf '{"result":{"pane":%s}}' "$pi" ;;
	esac
	;;
"plugin list")
	printf '{"result":{"plugins":[{"plugin_id":"annotate","plugin_root":"%s"}]}}' "$PLUGIN/lite"
	;;
"notification show")
	printf '%s\n' "$3" >"$TMP/notify"
	;;
esac
STUB
chmod 755 "$tmp/bin/herdr"

run() {
	rm -f "$tmp/argv" "$tmp/context" "$tmp/notify"
	env -i PATH="/usr/bin:/bin" \
		HERDR_BIN_PATH="$tmp/bin/herdr" \
		HERDR_ACTIVE_PANE_ID="$1" \
		XDG_STATE_HOME="$tmp/state" \
		XDG_CONFIG_HOME="$tmp/config" \
		TMP="$tmp" PLUGIN="$tmp/plugin" ${NO_AGENT:+NO_AGENT=1} \
		sh "$helper"
}

# Focus in fresh: the sibling pi pane is the target.
run w1:p1
grep -q '^paste-archive$' "$tmp/argv" || { echo "wrong argv in $(cat "$tmp/argv")" >&2; exit 1; }
python3 - "$tmp/context" <<'PY' || exit 1
import json, sys
context = json.load(open(sys.argv[1]))
assert context["focused_pane_id"] == "w1:p2", context
assert context["focused_pane_agent"] == "pi", context
assert context["tab_id"] == "w1:t1", context
PY
grep -q '/herdr/plugins/annotate$' "$tmp/state" || { echo "wrong state dir: $(cat "$tmp/state")" >&2; exit 1; }

# Focus already in the agent pane: itself, not a neighbour.
run w1:p2
python3 - "$tmp/context" <<'PY' || exit 1
import json, sys
assert json.load(open(sys.argv[1]))["focused_pane_id"] == "w1:p2"
PY

# No agent at all: notify, run nothing.
NO_AGENT=1 run w1:p1
[ ! -f "$tmp/argv" ] || { echo "ran the plugin with no agent" >&2; exit 1; }
grep -q 'No agent to paste into' "$tmp/notify" || { echo "no notice given" >&2; exit 1; }

echo "herdr-annotate-paste: ok"
