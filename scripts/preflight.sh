#!/usr/bin/env bash
# Release preflight: what has to hold before a release is tagged.
#
# Deliberately Apple-free, Docker-free and network-free, so the same script is
# both the local `make release-preflight` and the CI gate in
# .github/workflows/release.yml. It checks the things this repo can actually
# get wrong: a shipped script that does not parse, a version that disagrees
# with itself, and a release input that quietly went missing.
#
# Usage: preflight.sh [expected-version]
#   expected-version  optional; the version the release tag claims, e.g. 1.2.3
#                     or v1.2.3. Passed by the release workflow so a tag that
#                     does not match VERSION fails before anything is built.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"
expected="${1:-}"

failures=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
    printf '  FAIL  %s\n' "$1"
    failures=$((failures + 1))
}

echo "preflight: shell syntax"

# Mash's own scripts. packaging/plugins is other projects' code with its own
# tests, so it is not parsed here.
shell_files() {
    find packaging scripts \
        -maxdepth 2 -type f \
        ! -path 'packaging/plugins/*' ! -path 'packaging/defaults/*' \
        ! -path '*/__pycache__/*' \
        -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            head -c 200 "$f" 2>/dev/null | grep -qE '^#!.*\b(sh|bash|zsh)\b' && printf '%s\0' "$f"
        done
}

parsed=0
while IFS= read -r -d '' f; do
    # Handles both `#!/bin/bash` and `#!/usr/bin/env bash`. Taking the last
    # interpreter-looking word covers the env form and any flags after it.
    interp="$(head -n 1 "$f" | grep -oE '\b(bash|zsh|sh)\b' | tail -1)"
    if [ -z "$interp" ] || ! command -v "$interp" >/dev/null 2>&1; then
        ok "$f (skipped, no interpreter)"
        continue
    fi
    if "$interp" -n "$f" 2>/dev/null; then
        parsed=$((parsed + 1))
    else
        bad "$f does not parse under $interp"
        "$interp" -n "$f" 2>&1 | sed 's/^/          /' || true
    fi
done < <(shell_files)
[ "$failures" -eq 0 ] && ok "$parsed script(s) parsed"

echo "preflight: version agrees with itself"

version="$(tr -d '[:space:]' <VERSION 2>/dev/null || true)"
if printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "VERSION is $version"
else
    bad "VERSION is not X.Y.Z (got '${version:-<missing>}')"
fi

cfg_version="$(sed -nE 's/^current_version[[:space:]]*=[[:space:]]*//p' .bumpversion.cfg | tr -d '[:space:]')"
if [ "$cfg_version" = "$version" ]; then
    ok ".bumpversion.cfg agrees"
else
    bad ".bumpversion.cfg says '${cfg_version:-<none>}' but VERSION says '${version:-<none>}'"
fi

if [ -n "$expected" ]; then
    want="${expected#v}"
    if [ "$want" = "$version" ]; then
        ok "tag $expected matches VERSION"
    else
        bad "tag $expected does not match VERSION ($version)"
    fi
fi

echo "preflight: release inputs are present"

inputs=(
    packaging/build.sh
    packaging/carry.sh
    packaging/lib.sh
    packaging/release.sh
    packaging/mash
    packaging/mash-shell
    packaging/herdr-pane
    packaging/uninstall
    packaging/Mash.icns
    packaging/entitlements.plist
    packaging/entitlements-ghostty.plist
    packaging/entitlements-python.plist
    packaging/patch-ghostty-menu.py
    packaging/fresh-gpl-notice.txt
    packaging/pins.txt
    packaging/wizard/Cargo.toml
    .gitchangelog.rc
    .gitchangelog.tpl
)
missing=0
for f in "${inputs[@]}"; do
    [ -e "$f" ] || {
        bad "$f is missing"
        missing=$((missing + 1))
    }
done
[ "$missing" -eq 0 ] && ok "${#inputs[@]} file(s) present"

# Advisory only. shellcheck is on GitHub's ubuntu runners but not required on a
# maintainer's machine, and its findings have never been triaged here, so this
# reports without failing. Tighten to a real gate once the baseline is clean.
if command -v shellcheck >/dev/null 2>&1; then
    echo "preflight: shellcheck (advisory)"
    while IFS= read -r -d '' f; do
        shellcheck -S warning "$f" || true
    done < <(shell_files)
    ok "shellcheck ran (advisory, does not fail the run)"
else
    echo "preflight: shellcheck not installed (skipped)"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "preflight: PASSED"
    exit 0
fi
echo "preflight: FAILED ($failures problem(s))"
exit 1
