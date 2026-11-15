#!/bin/bash
# A pin decided by the manifest, not by wherever a branch happens to be.
#
# mash_clone_pinned used to clone the component's branch and refuse the build
# when HEAD differed from the manifest's commit. Upstream pushing to `main` was
# therefore a build outage: `annotate` moved between 0.5.1 and 0.5.2 and every
# platform of the 0.5.2 artifact build failed, while the pinned commit was
# still present and correct upstream.
#
# The check runs against real local repositories -- no network -- with the
# branch moved past the pin, the pin missing entirely, and no pin recorded.
#
# Run with: bash packaging/tests/test_clone_pinned.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# A repository with two commits; the pin will be the first of them.
upstream="$tmp/upstream"
mkdir -p "$upstream"
git -C "$upstream" init -q -b main
git -C "$upstream" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
first="$(git -C "$upstream" rev-parse HEAD)"
git -C "$upstream" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
second="$(git -C "$upstream" rev-parse HEAD)"
[ "$first" != "$second" ] || fail "fixture did not move the branch"

# drive <ref> <commit> <destination> -> mash_clone_pinned with those pins.
drive() {
  local ref="$1" commit="$2" dest="$3" status=0
  PIN_REF="$ref" PIN_COMMIT="$commit" bash -c '
    set -eu
    source "$1"
    mash_ref() { printf "%s" "${PIN_REF:-}"; }
    mash_commit() { printf "%s" "${PIN_COMMIT:-}"; }
    mash_clone_pinned fixture "$2" "$3"
  ' bash "$root/packaging/carry.sh" "$upstream" "$dest" || status=$?
  return "$status"
}

# --- the branch moved past the pin: build the pin, report the drift ---------
out="$(drive main "$first" "$tmp/moved" 2>&1)" || fail "a moved branch failed the build: $out"
[ "$(git -C "$tmp/moved" rev-parse HEAD)" = "$first" ] || fail "the moved branch was not reset to the pin"
case "$out" in
*"pinned at ${first:0:12}"*) ;;
*) fail "the pinned commit was not reported: $out" ;;
esac

# --- the branch is still at the pin: unchanged behaviour --------------------
out="$(drive main "$second" "$tmp/current" 2>&1)" || fail "an unmoved branch failed: $out"
[ "$(git -C "$tmp/current" rev-parse HEAD)" = "$second" ] || fail "an unmoved branch was altered"

# --- no pin recorded: clone the ref and say so ------------------------------
out="$(drive main "" "$tmp/unpinned" 2>&1)" || fail "a component with no pin failed: $out"
case "$out" in
*"no pinned commit"*) ;;
*) fail "an unpinned component was not announced: $out" ;;
esac

# --- the pin does not exist upstream: fail, and name the fix ----------------
if out="$(drive main 0000000000000000000000000000000000000000 "$tmp/missing" 2>&1)"; then
  fail "a pin missing upstream was accepted: $out"
fi
case "$out" in
*"no longer contains"*"Update packaging/assets.json"*) ;;
*) fail "a missing pin was not explained: $out" ;;
esac

echo "clone pinned: ok"
