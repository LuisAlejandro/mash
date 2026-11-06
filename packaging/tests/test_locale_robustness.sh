#!/bin/bash
# Mash's scripts must give the same answers whatever locale the user runs.
#
# Two things can break that: a script that parses localized output (sort order,
# date names, decimal commas) without pinning LC_ALL=C, and a script that
# crashes or changes behaviour when LANG names a locale the host lacks. This
# suite reruns the helper suites and the update/watcher suites under both
# conditions, and checks that the git watcher reports the same state in a
# Japanese UTF-8 locale as in C.
#
# Exit 77 when de_DE.UTF-8 is not installed on this host: the runner then
# reports the suite as skipped instead of passing a check that never ran.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root" || exit 1

GERMAN=de_DE.UTF-8
MISSING=zz_ZZ.UTF-8

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# Python's setlocale raises when the host has no such locale, which is the
# only portable probe: `locale -a` spells names differently on macOS and Linux.
have_locale() {
	python3 -c 'import locale,sys; locale.setlocale(locale.LC_ALL, sys.argv[1])' "$1" 2>/dev/null
}

if ! have_locale "$GERMAN"; then
	printf 'SKIP: %s is not installed on this host\n' "$GERMAN" >&2
	exit 77
fi
if have_locale "$MISSING"; then
	fail "$MISSING exists on this host; pick another missing locale name"
fi

# The suites that parse command output: the helper suites, the update
# suites (version and timestamp handling) and the PR watcher poll.
suites=()
while IFS= read -r s; do suites+=("$s"); done < <(
	find packaging/helpers/tests -maxdepth 1 -name 'test-*.sh' | sort
	find packaging/tests -maxdepth 1 -name 'test_mash_update_*.sh' | sort
	echo packaging/tests/test_pr_watch_poll.sh
)

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

run_suites() {
	local label="$1" s status
	shift
	for s in "${suites[@]}"; do
		env "$@" bash "$s" >"$log" 2>&1
		status=$?
		case "$status" in
		0) ;;
		77)
			# Same convention as ./scripts/test.sh: optional suites skip with 77.
			cat "$log" >&2
			printf 'SKIP: %s under %s\n' "$s" "$label" >&2
			;;
		*)
			cat "$log" >&2
			fail "$s failed under $label"
			;;
		esac
	done
	printf 'PASS: %d suite(s) under %s\n' "${#suites[@]}" "$label"
}

run_suites "$GERMAN" LC_ALL="$GERMAN" LANG="$GERMAN"
run_suites "missing locale $MISSING" LC_ALL="$MISSING" LANG="$MISSING"

# The git watcher's parsed output (branch, ahead/behind counts) must not
# change with the user's locale. Run it against a real repo with a local
# upstream, once under ja_JP.UTF-8 and once under C, and compare the state.
if have_locale ja_JP.UTF-8; then
	work="$(mktemp -d)"
	trap 'rm -rf "$work" "$log"' EXIT
	git init -q --bare "$work/remote.git" || fail "bare remote"
	git init -q "$work/repo" || fail "repo"
	(
		cd "$work/repo" || exit 1
		git config user.email locale@test.invalid
		git config user.name locale
		git commit -q --allow-empty -m base
		git remote add origin "$work/remote.git"
		git push -q origin HEAD:main
		git branch -q --set-upstream-to=origin/main
		git commit -q --allow-empty -m ahead
	) || fail "could not build the watcher fixture"

	# A herdr stub that answers the two reads the watchers make, and accepts
	# every metadata write.
	bin="$work/bin"
	mkdir -p "$bin" "$work/.mash/state"
	cat >"$bin/herdr" <<STUB
#!/bin/sh
case "\$*" in
  "pane list") printf '%s' '{"result":{"panes":[{"workspace_id":"ws-1","cwd":"$work/repo"}]}}' ;;
  "workspace list") printf '%s' '{"result":{"workspaces":[{"workspace_id":"ws-1"}]}}' ;;
  *) printf '%s' '{"result":{}}' ;;
esac
STUB
	chmod +x "$bin/herdr"
	# A gh stub with one open PR, approved and green, plus the review-thread
	# query the watcher makes for it. The PR watcher parses both replies.
	cat >"$bin/gh" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "pr list") printf '%s' '[{"number":7,"isDraft":false,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}],"url":"https://github.com/example/repo/pull/7"}]' ;;
  "api graphql") printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
  *) exit 1 ;;
esac
STUB
	chmod +x "$bin/gh"

	watch_state() {
		local name="$1" locale="$2" state_root
		state_root="$work/.mash/state-$name"
		env -i PATH="$bin:$PATH" HOME="$HOME" LANG="$locale" LC_ALL="$locale" \
			XDG_STATE_HOME="$state_root" \
			python3 "$root/packaging/helpers/git-status-watch" --no-fetch >/dev/null ||
			fail "git-status-watch failed under $locale"
		cp "$state_root/git-status-watch/state.json" "$work/state-$name.json" || fail "no state written under $locale"
	}
	watch_state ja ja_JP.UTF-8
	watch_state c C
	cmp -s "$work/state-ja.json" "$work/state-c.json" ||
		fail "git-status-watch state differs between ja_JP.UTF-8 and C"
	grep -q '"ahead": 1' "$work/state-c.json" || fail "git-status-watch did not count the ahead commit"
	printf 'PASS: git-status-watch state identical under ja_JP.UTF-8 and C\n'

	pr_state() {
		local name="$1" locale="$2" state_root
		state_root="$work/.mash/state-$name"
		env -i PATH="$bin:$PATH" HOME="$HOME" LANG="$locale" LC_ALL="$locale" \
			XDG_STATE_HOME="$state_root" \
			python3 "$root/packaging/helpers/pr-watch-repo" --quiet >/dev/null ||
			fail "pr-watch-repo failed under $locale"
		cp "$state_root/pr-watch-repo/state.json" "$work/pr-$name.json" || fail "no PR state written under $locale"
	}
	pr_state ja ja_JP.UTF-8
	pr_state c C
	cmp -s "$work/pr-ja.json" "$work/pr-c.json" ||
		fail "pr-watch-repo state differs between ja_JP.UTF-8 and C"
	printf 'PASS: pr-watch-repo state identical under ja_JP.UTF-8 and C\n'
fi

printf 'PASS: locale robustness\n'
