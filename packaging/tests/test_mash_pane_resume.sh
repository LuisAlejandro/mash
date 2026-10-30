#!/usr/bin/env bash
# mash-pane-resume reopens the agent a restored pane was running, from the
# ledger the pi extension keeps. It must run the recorded command once, fall
# back to a new pi when the session file is gone, refuse anything but pi, and
# return quietly when there is nothing to resume -- every pane shell runs it.
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/helpers/mash-pane-resume"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state/mash/pane-resume"
# A stand-in pi that records how it was called.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >"%s/ran"\n' "$tmp" >"$tmp/bin/pi"
chmod +x "$tmp/bin/pi"
entry="$tmp/state/mash/pane-resume/w5_p2"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run() {
	rm -f "$tmp/ran"
	env -i PATH="$tmp/bin:/usr/bin:/bin" XDG_STATE_HOME="$tmp/state" HERDR_PANE_ID="${1:-w5:p2}" \
		/bin/bash "$helper"
}

# Nothing recorded: return 1 without output, so the shell continues to its prompt.
out="$(run 2>&1)" && fail "no entry must return non-zero"
[ -z "$out" ] || fail "no entry must print nothing, got: $out"

# A recorded session that exists: pi reopens it, and only once.
session="$tmp/s.jsonl"
touch "$session"
printf 'pi\n--session\n%s\n' "$session" >"$entry"
run
[ "$(cat "$tmp/ran")" = "--session $session" ] || fail "did not resume the session: $(cat "$tmp/ran")"
[ ! -e "$entry" ] || fail "the entry must be taken, or a pi that exits at once would loop"
run && fail "a second shell in the same pane must not resume again"

# A session file that is gone by now: a new pi, never `pi --session <missing>`,
# which exits 1 and leaves a shell.
printf 'pi\n--session\n%s\n' "$tmp/gone.jsonl" >"$entry"
run
[ "$(cat "$tmp/ran")" = "" ] || fail "a missing session must start a new pi, got: $(cat "$tmp/ran")"

# Only pi, by plain name, is ever started from the ledger.
for bad in '/usr/bin/pi' 'rm' 'sh'; do
	printf '%s\n-rf\n/\n' "$bad" >"$entry"
	run && fail "must refuse to run '$bad'"
	[ ! -e "$tmp/ran" ] || fail "ran something for '$bad'"
done

# A pane id that could escape the ledger directory is ignored.
for bad in '../x' 'w5:p2/..' ''; do
	run "$bad" && fail "must ignore pane id '$bad'"
done

echo "mash-pane-resume: ok"
