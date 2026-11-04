#!/usr/bin/env bash
# packaging/assets.json is the single authority for pinned versions. A version
# written into a build script is a second source of truth: the manifest bump
# then changes nothing, and nothing reports the disagreement.
#
# Two checks, and the second is the one that matters:
#
#   1. The staging code resolves each pinned value from the manifest.
#   2. No build script still carries the literal it replaced, so a future edit
#      cannot quietly reintroduce one.
#
# Components deliberately exempt are listed with their reason; an exemption has
# to be stated here rather than left as an unexplained literal in a script.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
export work="${TMPDIR:-/tmp}/mash-pin-test.$$"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

fail=0
note() { printf 'ok    %s\n' "$1"; }
bad() {
  printf 'FAIL  %s\n' "$1" >&2
  fail=1
}

# shellcheck source=../carry.sh
source "$root/packaging/carry.sh"
# shellcheck source=../build-common.sh
source "$root/packaging/build-common.sh"

target="$(python3 "$root/packaging/assets.py" target)"

# --- 1. the resolvers answer from the manifest ------------------------------
expect() {
  local label="$1" got="$2" want="$3"
  [ "$got" = "$want" ] || {
    bad "$label resolved '$got', manifest says '$want'"
    return
  }
  note "$label resolves from the manifest"
}

manifest_version() {
  python3 "$root/packaging/assets.py" pins | sed -n "s/^$1 //p"
}

for component in fresh fullerzz.sesh hindsight-embed chrome-devtools-mcp \
  mash-programming-skills node python rust go viu zsh-autosuggestions; do
  expect "$component" "$(mash_version "$component")" "$(manifest_version "$component")"
done

# Git refs: the clone must name the manifest's ref, not its own tag.
for component in fullerzz.sesh herdr.auto-title persiyanov.reviewr ray.plugin-manager; do
  want="$(python3 "$root/packaging/assets.py" resolve-shell "$component" "$target" |
    sed -n 's/^REF=//p')"
  expect "$component ref" "$(mash_ref "$component")" "$want"
done

# npm specs carry the version in the same argument as the name.
expect "typebox spec" "$(mash_package_spec typebox)" "typebox@$(manifest_version typebox)"

# --- 2. no build script still hardcodes a pinned version --------------------
# Each entry is a component and a pattern that would appear only in a
# hardcoded reference to its pinned version.
check_absent() {
  local label="$1" pattern="$2" hit
  hit="$(grep -rnE "$pattern" \
    "$root/packaging/build.sh" \
    "$root/packaging/build-linux.sh" \
    "$root/packaging/build-common.sh" \
    "$root/packaging/carry.sh" 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    bad "$label is still hardcoded:"
    printf '%s\n' "$hit" >&2
    return
  fi
  note "$label is not hardcoded in any build script"
}

node_version="$(manifest_version node)"
python_version="$(manifest_version python)"
rust_version="$(manifest_version rust)"
go_version="$(manifest_version go)"
fresh_version="$(manifest_version fresh)"
zsh_version="$(manifest_version zsh-autosuggestions)"
typebox_version="$(manifest_version typebox)"
chrome_version="$(manifest_version chrome-devtools-mcp)"
hindsight_version="$(manifest_version hindsight-embed)"
skills_version="$(manifest_version mash-programming-skills)"

check_absent "node ($node_version)" "node-v${node_version}-|nodejs\.org/dist/v${node_version}"
check_absent "python ($python_version)" "cpython-${python_version}"
check_absent "rust ($rust_version)" "rust-${rust_version}-"
check_absent "go ($go_version)" "go${go_version}\."
check_absent "fresh ($fresh_version)" "fresh-${fresh_version}[^\"']|tags/v${fresh_version}"
check_absent "zsh-autosuggestions ($zsh_version)" "zsh-autosuggestions-${zsh_version}"
check_absent "typebox ($typebox_version)" "typebox@${typebox_version}"
check_absent "chrome-devtools-mcp ($chrome_version)" "chrome-devtools-mcp@${chrome_version}"
check_absent "hindsight ($hindsight_version)" "printf '${hindsight_version}"
check_absent "mash-programming-skills ($skills_version)" "!= \"${skills_version}\""

# The external plugin clones must not name a tag of their own.
check_absent "plugin clone refs" '--branch v[0-9]+\.[0-9]+\.[0-9]+'

# Pinned release binaries the macOS adapter used to fetch by literal URL.
for component in gh lazygit lazydocker pet atuin starship; do
  version="$(manifest_version "$component")"
  check_absent "$component ($version)" "releases/download/v?${version}/"
done

# --- 3. shared downloads verify on stock macOS as well as Linux --------------
printf 'Mash download check\n' >"$work/checksum-source"
checksum="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$work/checksum-source")"
if mash_download "file://$work/checksum-source" "$checksum" "$work/checksum-copy" &&
  cmp -s "$work/checksum-source" "$work/checksum-copy"; then
  note "shared downloader verifies release bytes"
else
  bad "shared downloader rejected a valid checksum"
fi
if mash_download "file://$work/checksum-source" "$(printf '%064d' 0)" "$work/checksum-bad"; then
  bad "shared downloader accepted a wrong checksum"
fi
if command -v shasum >/dev/null 2>&1; then
  # Force the stock macOS path even on a runner that also has GNU coreutils.
  (
    command() {
      if [ "$1" = -v ] && [ "${2:-}" = sha256sum ]; then return 1; fi
      builtin command "$@"
    }
    mash_verify_sha256 "$checksum" "$work/checksum-source"
  ) && note "checksum verification works without sha256sum" || bad "shasum fallback failed"
fi

# --- exemptions, each with its reason ---------------------------------------
# herdr:       macOS uses a Homebrew bottle whose dylibs are rewritten into the
#              bundle; the URL is resolved from the manifest, the mechanism is
#              not the shared one.
# CUA_DRIVER:  passed to a vendor install script Mash does not checksum.
# blueprint:   CI clones its own tag; the Linux build checks the manifest.
# Zig/Metal:   not manifest components.

if [ "$fail" -ne 0 ]; then
  printf '\nA pinned version lives outside packaging/assets.json.\n' >&2
  exit 1
fi
printf '\nthe manifest is the only source of these pins\n'
