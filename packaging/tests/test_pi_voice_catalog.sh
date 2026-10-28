#!/usr/bin/env bash
# The dictation helper reads defaults/pi/catalog from the installed tree, not
# from the Pi Voice package. Both adapters must stage that copy from the
# pi-voice the bundle actually ships, and reject a stale vendored catalog.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../build-common.sh
source "$root/packaging/build-common.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

res="$tmp/res"
src="$res/node/lib/node_modules/@earendil-works/pi-voice/catalog"
mkdir -p "$src" "$res/defaults"
cp "$root/packaging/wizard/data/catalog.json" "$src/catalog.json"
cp "$root/packaging/wizard/data/recommendations.json" "$src/recommendations.json"

mash_stage_pi_voice_catalog "$res" || {
  echo "the shared catalog stager failed" >&2
  exit 1
}
for file in catalog.json recommendations.json; do
  cmp "$src/$file" "$res/defaults/pi/catalog/$file" || {
    echo "the staged catalog differs from the bundled pi-voice: $file" >&2
    exit 1
  }
done

# A vendored catalog that no longer matches the bundle would make the wizard
# offer models the extension cannot resolve, so staging must fail loudly.
printf '{}\n' >"$src/catalog.json"
if mash_stage_pi_voice_catalog "$res" 2>/dev/null; then
  echo "the stager accepted a stale vendored catalog" >&2
  exit 1
fi
