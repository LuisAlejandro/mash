#!/bin/bash
# An upgrade must move a user's Pi settings onto the Pi packages the bundle ships.
#
# settings.json is the user's once they edit it, so it kept the old
# `npm:pi-subagents@0.76.0` an earlier Mash seeded. Pi resolves a pin the
# bundled copy does not satisfy by downloading that version into pi/agent/npm
# and loading it, so the upgrade (and its security fix) never took effect.
# Only older pins of bundled packages may move; everything else is the user's.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
sync="$root/packaging/helpers/mash-seed-sync"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
res="$tmp/res"
d="$tmp/data"
failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
json() { python3 -c "import json,sys; v=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2])))" "$@"; }

shipped() { # subagents-version ask-user-version bundle-version
  mkdir -p "$res/defaults/pi"
  printf '%s\n' "$3" >"$res/VERSION"
  : >"$res/defaults/optional-programming.txt"
  printf '{\n  "packages": [\n    "npm:pi-subagents@%s",\n    "npm:pi-ask-user@%s",\n    "npm:@scope/pi-theme@1.0.0"\n  ]\n}\n' "$1" "$2" \
    >"$res/defaults/pi/settings.json"
}
installed() { # name version
  mkdir -p "$d/pi/agent/npm/node_modules/$1"
  printf '{"name":"%s","version":"%s"}\n' "$1" "$2" >"$d/pi/agent/npm/node_modules/$1/package.json"
}
run_sync() { PYTHONDONTWRITEBYTECODE=1 "$sync" "$res" "$d" >/dev/null 2>&1; }

mkdir -p "$d/setup"
shipped 0.76.0 0.17.0 1.0.0
run_sync
chk "first launch seeds the shipped settings" \
  '[ "$(json "$d/pi/agent/settings.json" "v[\"packages\"][0]")" = "\"npm:pi-subagents@0.76.0\"" ]'

# The user edits settings.json and adds a package of their own; Pi has
# downloaded copies of two bundled packages, one older and one they chose newer.
python3 - "$d/pi/agent/settings.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["defaultThinkingLevel"] = "high"
s["packages"] = ["npm:pi-subagents@0.76.0", {"source": "npm:pi-ask-user@0.99.0"},
                 "npm:@scope/pi-theme@1.0.0", "npm:pi-btw"]
json.dump(s, open(p, "w"), indent=2)
PY
installed pi-subagents 0.76.0
installed pi-ask-user 0.99.0
installed pi-btw 0.8.0
printf '{"dependencies":{"pi-subagents":"^0.76.0","pi-ask-user":"^0.99.0","pi-btw":"^0.8.0"}}\n' \
  >"$d/pi/agent/npm/package.json"

shipped 0.85.0 0.17.2 2.0.0
run_sync
s="$d/pi/agent/settings.json"
chk "an older bundled pin moves to the bundle's version" \
  '[ "$(json "$s" "v[\"packages\"][0]")" = "\"npm:pi-subagents@0.85.0\"" ]'
chk "a newer version the user chose is kept" \
  '[ "$(json "$s" "v[\"packages\"][1][\"source\"]")" = "\"npm:pi-ask-user@0.99.0\"" ]'
chk "a user's own package is kept" '[ "$(json "$s" "v[\"packages\"][3]")" = "\"npm:pi-btw\"" ]'
chk "the user's other settings are kept" '[ "$(json "$s" "v[\"defaultThinkingLevel\"]")" = "\"high\"" ]'
chk "Pi's stale copy of a bundled package is removed" '[ ! -e "$d/pi/agent/npm/node_modules/pi-subagents" ]'
chk "a newer copy the user chose stays" '[ -f "$d/pi/agent/npm/node_modules/pi-ask-user/package.json" ]'
chk "a package Mash does not ship stays" '[ -f "$d/pi/agent/npm/node_modules/pi-btw/package.json" ]'
chk "the stale copy leaves Pi's npm manifest" \
  '[ "$(json "$d/pi/agent/npm/package.json" "sorted(v[\"dependencies\"])")" = "[\"pi-ask-user\", \"pi-btw\"]" ]'

# Idempotent: a second pass over a reconciled folder changes nothing.
before="$(cat "$s" "$d/pi/agent/npm/package.json" | cksum)"
printf '2.0.1\n' >"$res/VERSION"
run_sync
chk "a second pass changes nothing" '[ "$(cat "$s" "$d/pi/agent/npm/package.json" | cksum)" = "$before" ]'

# A user can relocate their npm tree, a scope, or one package with a symlink.
# Never traverse one to delete a package outside Mash's data directory.
for relative in node_modules node_modules/@scope node_modules/pi-subagents; do
  d="$tmp/data-${relative//\//-}"
  outside="$tmp/outside-${relative//\//-}"
  link="$d/pi/agent/npm/$relative"
  case "$relative" in
    node_modules) metadata="$outside/pi-subagents/package.json" ;;
    node_modules/@scope) metadata="$outside/pi-theme/package.json" ;;
    *) metadata="$outside/package.json" ;;
  esac
  mkdir -p "$(dirname "$metadata")" "$(dirname "$link")"
  printf '{"version":"0.1.0"}\n' >"$metadata"
  cp "$metadata" "$tmp/expected.json"
  ln -s "$outside" "$link"
  printf '{"dependencies":{"pi-subagents":"^0.76.0","@scope/pi-theme":"^0.1.0"}}\n' \
    >"$d/pi/agent/npm/package.json"
  cp "$d/pi/agent/npm/package.json" "$tmp/expected-npm.json"
  if ! run_sync; then fail "sync with symlinked $relative"; fi
  chk "outside package behind $relative stays intact" 'cmp -s "$metadata" "$tmp/expected.json"'
  chk "the $relative symlink stays intact" '[ -L "$link" ]'
  chk "dependencies behind $relative stay registered" \
    'cmp -s "$d/pi/agent/npm/package.json" "$tmp/expected-npm.json"'
done

# Cleanup may not replace a user's symlinked manifest, and a non-object
# manifest must not crash first-launch reconciliation.
for kind in symlink nonobject; do
  d="$tmp/data-manifest-$kind"
  installed pi-subagents 0.76.0
  manifest="$d/pi/agent/npm/package.json"
  if [ "$kind" = symlink ]; then
    printf '{"dependencies":{"pi-subagents":"^0.76.0"}}\n' >"$tmp/outside-manifest.json"
    ln -s "$tmp/outside-manifest.json" "$manifest"
  else
    printf '[]\n' >"$tmp/outside-manifest.json"
    cp "$tmp/outside-manifest.json" "$manifest"
  fi
  if ! run_sync; then fail "sync with $kind npm manifest"; fi
  chk "a $kind npm manifest is kept" 'cmp -s "$manifest" "$tmp/outside-manifest.json"'
  if [ "$kind" = symlink ]; then
    chk "the npm manifest symlink is kept" '[ -L "$manifest" ]'
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "test_seed_pi_packages: PASSED"
  exit 0
fi
echo "test_seed_pi_packages: FAILED ($failures problem(s))"
exit 1
