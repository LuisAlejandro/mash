#!/usr/bin/env bash
# mash-pane-resume reopens the agent a restored pane was running, from the
# ledger the pi extension keeps. It must run the recorded command once, fall
# back to a new pi when the session file is gone, refuse anything but pi, and
# return quietly when there is nothing to resume -- every pane shell runs it.
#
# This is the ledger's half of the restore contract, tested without a Herdr
# server: the helper's whole job is a decision -- given an entry and a pane,
# does it start pi? -- and that decision is what any fix for the double-restore
# race (test_pi_restore_ownership.sh) would change. The logout case lives here
# rather than against a live server because the shape that produces it depends
# on Herdr's own polling and screen reading, which a test cannot drive without
# asserting Herdr's behaviour instead of Mash's.
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
		${2:+HERDR_BIN_PATH="$2"} /bin/bash "$helper"
}

# A stand-in herdr whose `pane get` answers with or without a pi claim on the
# pane. $1 is the agent field to report; empty means the pane holds none.
stub_herdr() {
	local agent="${1:-}" path="$tmp/bin/herdr-stub"
	if [ -n "$agent" ]; then
		printf '#!/bin/sh\nprintf \x27{"result":{"pane":{"pane_id":"w5:p2","agent":"%s","agent_status":"idle"}}}\\n\x27\n' \
			"$agent" >"$path"
	else
		printf '#!/bin/sh\nprintf \x27{"result":{"pane":{"pane_id":"w5:p2","agent_status":"unknown"}}}\\n\x27\n' >"$path"
	fi
	chmod +x "$path"
	printf '%s' "$path"
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

# --- the logout case, which is the reason this helper exists ----------------
# At logout macOS kills pi about twenty seconds before Herdr stops. Herdr keeps
# a resume command only while the agent that reported it runs, so it drops the
# command and saves the pane as a plain shell; the ledger entry is all that is
# left of the conversation (bcb9a9f). The shell the restore leaves in the pane
# runs this helper, and it must bring that conversation back.
#
# Each pane keeps its own entry. Herdr 0.9.3 resumes at most one pane per
# reporter source, and the same mistake here -- one shared entry -- would leave
# every pane after the first as a bare shell.
logout_session="$tmp/logout.jsonl"
touch "$logout_session"
for pane in w5:p2 w5:p3; do
	printf 'pi\n--session\n%s\n' "$logout_session" >"$tmp/state/mash/pane-resume/${pane/:/_}"
done
for pane in w5:p2 w5:p3; do
	run "$pane"
	[ "$(cat "$tmp/ran")" = "--session $logout_session" ] ||
		fail "a logout-shaped restore must reopen $pane's conversation, got: $(cat "$tmp/ran")"
done

# A fix for the double-restore race must not reach this helper by leaving the
# entry behind: a pane that is restored twice would then reopen pi twice.
for pane in w5:p2 w5:p3; do
	[ ! -e "$tmp/state/mash/pane-resume/${pane/:/_}" ] ||
		fail "$pane kept its ledger entry after being resumed"
done

# --- deferring to Herdr's own restore ---------------------------------------
# An ordinary restart needs nothing from this helper: pi was running when Herdr
# saved, so Herdr kept its resume command and replays it itself. Resuming here
# as well is what left `pi --session <file>` typed into a restored conversation
# (test_pi_restore_ownership.sh). Herdr reports the pane's agent as "pi" for
# exactly that case, and reports none once the record is gone.
printf 'pi\n--session\n%s\n' "$session" >"$entry"
# Declining is a non-zero exit, like every other "nothing to do" path here, so
# it must not take the suite down with it under `set -e`.
run w5:p2 "$(stub_herdr pi)" && fail "declining must still return non-zero"
[ ! -e "$tmp/ran" ] || fail "must not resume a pane Herdr is already restoring"
# The entry stays: it is this pane's only cover for the NEXT logout, and losing
# it here would trade the double restore for the older came-back-as-a-shell bug.
[ -f "$entry" ] || fail "must keep the ledger entry when Herdr owns the restore"

# The same pane once Herdr has let go of it -- a logout, or a pane whose pi
# exited later. The entry is still there, so the conversation comes back.
run w5:p2 "$(stub_herdr)"
[ "$(cat "$tmp/ran")" = "--session $session" ] ||
	fail "must resume when Herdr holds no claim, got: $(cat "$tmp/ran")"

# Herdr unreachable (no binary, socket down): resume anyway. A pane that comes
# back as a shell loses a conversation; a stray replayed line does not.
printf 'pi\n--session\n%s\n' "$session" >"$entry"
run w5:p2 "$tmp/bin/herdr-missing"
[ "$(cat "$tmp/ran")" = "--session $session" ] ||
	fail "must resume when herdr cannot be reached, got: $(cat "$tmp/ran")"

# A claim by some other agent is not pi's: that pane is not being restored as a
# pi conversation, so the ledger is still the only thing that can bring it back.
printf 'pi\n--session\n%s\n' "$session" >"$entry"
run w5:p2 "$(stub_herdr claude)"
[ "$(cat "$tmp/ran")" = "--session $session" ] ||
	fail "another agent's claim must not block a pi resume, got: $(cat "$tmp/ran")"

echo "mash-pane-resume: ok"
