#!/bin/bash
# The two launchers must seed ~/.mash through the same code.
#
# packaging/mash (macOS) and packaging/linux/launcher (Linux) both source
# packaging/launch-common.sh, which owns every seeding step. A launcher that
# also *defines* one of those functions shadows the shared one for its platform
# only: the definition is read after the source, so the local copy wins. That is
# how macOS came to miss the shell rc files, the Starship config, the tab bar's
# version substitution, the notifier config and the Pi integration repair --
# each had been added to the shared module, and the macOS copy never got them.
#
# Nothing here runs a launcher; a launcher opens an app. This asserts the shape
# that keeps them in step.
#
# Run with: bash packaging/tests/test_launcher_parity.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
shared="$root/packaging/launch-common.sh"
failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

for f in "$shared" "$root/packaging/mash" "$root/packaging/linux/launcher"; do
  [ -f "$f" ] || {
    echo "missing $f" >&2
    exit 1
  }
done

# Function definitions at column zero: `name() {`.
defs() { grep -oE '^[a-z_][a-z0-9_]*\(\)' "$1" | tr -d '()' | sort -u; }

shared_defs="$(defs "$shared")"
[ -n "$shared_defs" ] || {
  echo "no functions found in launch-common.sh; the parser broke" >&2
  exit 1
}

for launcher in packaging/mash packaging/linux/launcher; do
  shadowed="$(comm -12 <(defs "$root/$launcher") <(printf '%s\n' "$shared_defs"))"
  if [ -n "$shadowed" ]; then
    fail "$launcher redefines shared function(s): $(echo "$shadowed" | tr '\n' ' ')"
  else
    ok "$launcher defines no function that launch-common.sh already owns"
  fi
done

# Both launchers must actually call the shared entry point, or they would skip
# the seeding entirely rather than duplicate it.
for launcher in packaging/mash packaging/linux/launcher; do
  if grep -qE '^[[:space:]]*mash_seed_all[[:space:]]' "$root/$launcher"; then
    ok "$launcher seeds through mash_seed_all"
  else
    fail "$launcher does not call mash_seed_all"
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "test_launcher_parity: PASSED"
  exit 0
fi
echo "test_launcher_parity: FAILED ($failures problem(s))"
exit 1
