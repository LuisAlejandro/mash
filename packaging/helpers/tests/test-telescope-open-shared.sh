#!/usr/bin/env bash
# cmd+p must open a file in the editor beside it, private or shared.
#
# A private Fresh runs as a daemon named local-<pid>-<hash>, and that pid is
# what pins the file to its pane. A dev tab's Fresh is a client of its
# directory's shared daemon, named after whichever tab started it, so its own
# pid matches nothing. The fallback addresses the directory's daemon as "." --
# NOT "", which Fresh reads as a session literally named "" and starts as a
# hidden daemon. Without it every pick in a shared tab opened a new tab.
#
# Runs the real function from telescope-files against stub fresh and herdr.
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/telescope-files"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
project="$(cd "$tmp/project" && pwd -P)"

# The function under test, lifted verbatim so the test cannot drift from it.
awk '/^open_in_running_fresh\(\) \{/,/^\}/' "$helper" >"$tmp/fn.sh"
grep -q 'open_in_running_fresh()' "$tmp/fn.sh" || {
	echo "open_in_running_fresh not found in telescope-files" >&2
	exit 1
}

cat >"$tmp/bin/fresh" <<SH
#!/bin/sh
case "\$1 \$2 \$3" in
"--cmd daemon info") printf 'Running daemons:\n  %s\n' "\${FAKE_DAEMONS:-}" ;;
"--cmd daemon open-file") printf 'session=[%s] file=[%s] cwd=[%s]\n' "\$4" "\$5" "\$(pwd -P)" >"$tmp/opened" ;;
*) exit 2 ;;
esac
SH
cat >"$tmp/bin/herdr" <<SH
#!/bin/sh
[ "\$1 \$2 \$3" = "pane get w1:p2" ] && printf '{"result":{"pane":{"pane_id":"w1:p2","cwd":"%s"}}}\n' "$project"
exit 0
SH
cp "$(dirname "$helper")/herdr-json" "$tmp/bin/herdr-json"
chmod +x "$tmp/bin/"*

# $1 is the daemon list the stub reports; the rest are the function's arguments.
run() {
	rm -f "$tmp/opened"
	export FAKE_DAEMONS="$1"
	shift
	(
		editor="$tmp/bin/fresh" herdr="$tmp/bin/herdr" here="$tmp/bin"
		# shellcheck disable=SC1091
		. "$tmp/fn.sh"
		open_in_running_fresh "$@"
	)
}

# A private editor: its own pid names its daemon, so that daemon is used.
run 'local-4242-abc123' /x/file.txt 4242 w1:p2
grep -q '^session=\[local-4242-abc123\] file=\[/x/file.txt\]' "$tmp/opened" || {
	echo "a private editor was not reached through its own daemon: $(cat "$tmp/opened")" >&2
	exit 1
}

# A shared editor: no daemon carries this pane's pid, so the directory's is used.
run 'local-7777-other00' /x/file.txt 4242 w1:p2
grep -qx "session=\[\.\] file=\[/x/file.txt\] cwd=\[$project\]" "$tmp/opened" || {
	echo "a shared editor was not reached through its directory: $(cat "$tmp/opened" 2>/dev/null)" >&2
	exit 1
}

# No readable directory: report failure rather than open somewhere unseen.
if run '' /x/file.txt 4242 w9:p9; then
	echo "a pane with no directory still claimed an open" >&2
	exit 1
fi
[ ! -e "$tmp/opened" ] || {
	echo "a pane with no directory opened the file anyway" >&2
	exit 1
}

echo "telescope open in shared editor: ok"
