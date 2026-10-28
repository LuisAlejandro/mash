#!/usr/bin/env bash
# herdr-json must print the FIRST match for a key in document order, keep
# working on a pretty-printed reply, and print nothing (exit 0) for anything it
# cannot resolve. The first two pin the behaviour of the sed/grep extractors it
# replaced, which got both wrong: a greedy `.*` resolved a reply carrying
# several pane_ids to the LAST one (the wrong pane), and a line-based pattern
# matched nothing at all once the same reply was indented. Both are silent
# wrong answers, so a future refactor must not reintroduce either.
set -euo pipefail

helper="${1:-$(cd "$(dirname "$0")/.." && pwd)/herdr-json}"

fail() {
	echo "herdr-json: $1" >&2
	exit 1
}

# Field $1 of JSON $2, through the helper's stdin.
jget() {
	printf '%s' "$2" | "$helper" "$1"
}

# $3 is the payload read for $2; assert no output and a zero exit status.
expect_empty() {
	local out rc
	out="$(printf '%s' "$3" | "$helper" "$2")" && rc=0 || rc=$?
	[ "$rc" -eq 0 ] || fail "$1: exited $rc, expected 0"
	[ -z "$out" ] || fail "$1: printed '$out', expected nothing"
}

# 1. Flat reply, one key.
[ "$(jget pane_id '{"result":{"pane_id":"w1:p2"}}')" = "w1:p2" ] ||
	fail "flat pane_id: got '$(jget pane_id '{"result":{"pane_id":"w1:p2"}}')'"

# 2. One key, several levels deep and inside an array of objects (again, one
# occurrence only -- uniqueness is case 3's job, not this one's).
nested='{"id":"cli:pane:process_info","result":{"process_info":{"foreground_processes":[{"argv":["pi"],"name":"fresh","pid":10373}]}}}'
[ "$(jget name "$nested")" = "fresh" ] ||
	fail "nested name: got '$(jget name "$nested")'"

# 3. THE regression: several values for one key in a single document. Document
# order decides, so the reply's own tab object cannot shadow the pane it is
# about. The old greedy sed printed LEFT_PANE (and "node") here.
multi='{"result":{"tab":{"tab_id":"t1"},"panes":[{"pane_id":"RIGHT_PANE"},{"pane_id":"LEFT_PANE"}]}}'
[ "$(jget pane_id "$multi")" = "RIGHT_PANE" ] ||
	fail "multi-match pane_id: got '$(jget pane_id "$multi")', expected RIGHT_PANE (first in document order)"
[ "$(jget tab_id "$multi")" = "t1" ] ||
	fail "multi-match tab_id: got '$(jget tab_id "$multi")'"
two_procs='{"result":{"process_info":{"foreground_processes":[{"name":"atuin","pid":10373},{"name":"node","pid":85537}]}}}'
[ "$(jget name "$two_procs")" = "atuin" ] ||
	fail "multi-match name: got '$(jget name "$two_procs")', expected the first foreground process"

# 4. THE other regression: the same information, pretty-printed. A line-based
# extractor found nothing here.
pretty='{
  "result": {
    "tab": {
      "tab_id": "w1:t1",
      "label": ""
    },
    "panes": [
      {
        "pane_id": "RIGHT_PANE"
      },
      {
        "pane_id": "LEFT_PANE"
      }
    ]
  }
}'
[ "$(jget tab_id "$pretty")" = "w1:t1" ] ||
	fail "pretty-printed tab_id: got '$(jget tab_id "$pretty")'"
[ "$(jget pane_id "$pretty")" = "RIGHT_PANE" ] ||
	fail "pretty-printed pane_id: got '$(jget pane_id "$pretty")', expected RIGHT_PANE"

# 5. Absent key: no output, and NOT a failure -- callers treat empty as absent.
expect_empty "missing key" pane_id '{"result":{"pane":{}}}'

# 6. Malformed reply: truncated JSON, garbage, and a JSON scalar top level.
expect_empty "truncated JSON" pane_id '{"result":'
expect_empty "garbage" pane_id 'not json at all'
expect_empty "scalar reply" pane_id '"just a string"'

# 7. Empty stdin.
expect_empty "empty stdin" pane_id ''

# 8. A key whose value is an object or an array is NOT a field: the walker only
# prints scalars and keeps descending instead. Deliberate, so pin it.
expect_empty "object value" panes '{"result":{"panes":{"pane_id":"w1:p1"}}}'
expect_empty "object value, no scalar" pane_id '{"result":{"pane_id":{"nested":"x"},"focused":false}}'
expect_empty "array value" panes '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}'

# ...and the descent still reaches the scalars those containers hold.
[ "$(jget pane_id '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}')" = "w1:p1" ] ||
	fail "descent into array: got '$(jget pane_id '{"result":{"panes":[{"pane_id":"w1:p1"}]}}')'"

# 9. A numeric value comes out as written, not as a JSON repr ("85537", not
# "[85537]"): callers pass it straight to Fresh's daemon session name.
[ "$(jget pid '{"result":{"process_info":{"foreground_processes":[{"pid":85537}]}}}')" = "85537" ] ||
	fail "numeric pid: got '$(jget pid '{"result":{"process_info":{"foreground_processes":[{"pid":85537}]}}}')'"

echo "herdr-json: ok"
