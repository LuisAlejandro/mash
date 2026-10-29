#!/bin/bash
# The tab-bar label must follow the version without anyone editing a config.
#
# The right edge of Herdr's tab bar shows "Mash <version>", built from a
# `__MASH_VERSION__` placeholder substituted when the config is seeded, from the
# bundle's VERSION. The failure this pins: the label was the literal "Mash", so
# it never matched a release, and hardcoding the number instead would go stale on
# the next bumpversion.
#
# Two paths must substitute, because a fresh install and an upgrade take
# different ones:
#   mash_seed_configs   writes config.toml the first time
#   mash-seed-sync      refreshes it on upgrade, while the file is still the one
#                       Mash wrote
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { # check MSG CMD... -- record a pass when CMD succeeds
  local msg="$1"
  shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=../../packaging/launch-common.sh
. "$root/packaging/launch-common.sh"

# --- the shipped configs carry the placeholder, not a number ----------------
for name in config.toml config.linux.toml; do
  check "packaging/defaults/herdr/$name carries __MASH_VERSION__" \
    grep -q 'text = "Mash __MASH_VERSION__"' "$root/packaging/defaults/herdr/$name"
  check "packaging/defaults/herdr/$name has no hardcoded version" \
    bash -c '! grep -qE "text = \"Mash [0-9]" "$1"' _ "$root/packaging/defaults/herdr/$name"
done

# --- first install: mash_seed_configs substitutes it ------------------------
res="$tmp/res"
mkdir -p "$res/bin"
d="$tmp/data"
mkdir -p "$d/bin"
printf '9.9.9\n' >"$res/VERSION"          # a sentinel, not the real version
# The whole defaults tree, not a hand-picked subset. This fixture used to copy
# the handful of files mash_seed_configs was known to read, which made it a
# second, silent inventory of that function: adding a seeded file (starship.toml
# and the three shell rc files did exactly this) left the fixture behind, and
# the cp failures only surfaced as unrelated-looking assertion failures further
# down. Staging the real tree is what a bundle carries anyway.
cp -R "$root/packaging/defaults" "$res/defaults"
# carry.sh stages this inventory into every bundle beside the defaults.
: >"$res/defaults/optional-programming.txt"
for f in lib.sh launch-common.sh mash-shell; do cp "$root/packaging/$f" "$res/bin/$f"; done

# Seeding picks the platform suffix through uname; this test asserts the
# mechanism, so run it with a Darwin answer and a config.toml fixture.
seed_darwin() (
  uname() { printf 'Darwin\n'; }
  mash_seed_configs "$res" "$d"
)
seed_darwin
live="$d/config/herdr/config.toml"
check "a fresh install shows the bundle's version" \
  grep -q 'text = "Mash 9.9.9"' "$live"
check "no placeholder survives seeding" \
  bash -c '! grep -q "__MASH_VERSION__" "$1"' _ "$live"

# --- an upgrade: mash-seed-sync re-renders for an existing install ----------
d2="$tmp/upgraded"
mkdir -p "$d2/config/herdr" "$d2/local/state"
# The shape of the previous release: Mash wrote this at 0.1.0 and recorded it.
sed -e 's#__MASH_SHELL__#x#g' -e 's#__MASH_CONFIG__#y#g' \
  -e 's#__MASH_VERSION__#0.1.0#g' \
  "$root/packaging/defaults/herdr/config.toml" >"$d2/config/herdr/config.toml"
python3 - "$d2" <<'PY'
import hashlib, json, pathlib, sys
d = pathlib.Path(sys.argv[1])
f = d / "config/herdr/config.toml"
json.dump({"version": "0.1.0",
           "selection": {"programming": True, "design": False},
           "files": {"config/herdr/config.toml": hashlib.sha256(f.read_bytes()).hexdigest()}},
          open(d / "local/state/seeded.json", "w"))
PY
check "the upgrade fixture starts on the old version" \
  grep -q 'text = "Mash 0.1.0"' "$d2/config/herdr/config.toml"
"$root/packaging/helpers/mash-seed-sync" "$res" "$d2" >/dev/null 2>&1 || true
check "an upgrade refreshes the label to the bundle's version" \
  grep -q 'text = "Mash 9.9.9"' "$d2/config/herdr/config.toml"

# --- a config the user edited keeps their text ------------------------------
# Provenance is the contract: Mash updates a file while it still matches what it
# wrote. Someone who edited config.toml owns it, and their label stays theirs.
printf '# my tweak\n' >>"$d2/config/herdr/config.toml"
sed -i.bak 's#text = "Mash 9.9.9"#text = "Mash mine"#' "$d2/config/herdr/config.toml" && rm -f "$d2/config/herdr/config.toml.bak"
"$root/packaging/helpers/mash-seed-sync" "$res" "$d2" >/dev/null 2>&1 || true
check "a user-edited config is left alone" \
  grep -q 'text = "Mash mine"' "$d2/config/herdr/config.toml"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
