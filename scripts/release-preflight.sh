#!/usr/bin/env bash
# The local release gate: lint, test, then build the real macOS app.
#
#   make release-preflight          (also run by scripts/release.sh before the bump)
#
# scripts/preflight.sh stays the fast, offline consistency check that CI runs at
# the tag. This script proves the release instead: a tree that passes here has
# been linted, every suite has run, and dist/Mash.app was assembled from the
# pinned upstreams and its own patches -- the step only the post-tag artifact
# build used to reach. Three 0.5.2 attempts failed there with everything before
# the tag green: a build patch that no longer applied, an upstream branch that
# moved past its pin, and a clone that never returned.
#
# The build is the macOS one, natively and ad-hoc signed, as build.sh does it:
# no Docker, no Developer ID, no notarization. Those stay in the release CI.
# Lint is held to what passes today, so a new finding fails the gate while the
# backlog does not block every release; see the lint section.
#
# Environment:
#   MASH_PREFLIGHT_SKIP_BUILD=1  skip the build (for iterating on lint/tests only;
#                                scripts/release.sh refuses to honour it)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
expected="${1:-}"

failures=0
started="$(date +%s)"
step() { printf '\nrelease-preflight: %s\n' "$1"; }
ok() { printf '  ok    %s\n' "$1"; }
bad() {
    printf '  FAIL  %s\n' "$1"
    failures=$((failures + 1))
}
# Run a check, keep its output for a failure, show it only then. A suite runner
# prints one FAIL line per broken suite among thousands of passing ones, so the
# FAIL lines come first; the tail follows for anything else.
check() {
    local label="$1" log
    shift
    log="$(mktemp)"
    if "$@" >"$log" 2>&1; then
        ok "$label"
    else
        bad "$label"
        grep -E '^(FAIL|FAILED|error)' "$log" | sed 's/^/        /' | head -20
        echo "        ..."
        sed 's/^/        /' "$log" | tail -15
    fi
    rm -f "$log"
}

# The Rust crates Mash owns. Vendored plugins are other projects' code.
crates=(
    packaging/wizard
    packaging/pane-runner
    packaging/plugins/herdr-workspace
    packaging/plugins/telescope
)

python_sources() {
    find packaging scripts -name '*.py' \
        ! -path 'packaging/plugins/*' ! -path '*/target/*' ! -path '*/__pycache__/*'
    for f in packaging/helpers/*; do
        [ -f "$f" ] && head -n 1 "$f" | grep -q python && printf '%s\n' "$f"
    done
}

# --- 1. consistency (the same offline checks CI runs at the tag) ------------
step "consistency"
check "scripts/preflight.sh ${expected}" ./scripts/preflight.sh ${expected:+"$expected"}

# --- 2. lint and format ------------------------------------------------------
# Held to today's clean baseline. Rust is formatted, and clippy denies its
# correctness group: the style lints carry a backlog of about ninety findings
# that nobody has triaged, and gating on them would block every release on
# unrelated debt. Python is held to errors that change behaviour -- syntax, an
# undefined name, a broken comparison -- not to its style backlog.
step "lint and format"
for crate in "${crates[@]}"; do
    check "rustfmt ${crate}" cargo fmt --manifest-path "$crate/Cargo.toml" -- --check
    check "clippy (correctness) ${crate}" \
        cargo clippy --locked --quiet --manifest-path "$crate/Cargo.toml" --all-targets \
        -- -A clippy::all -D clippy::correctness -D warnings
done
if command -v ruff >/dev/null 2>&1; then
    # shellcheck disable=SC2046 # one argument per path is the point
    check "ruff (errors) on Mash's Python" ruff check --no-cache --select E9,F63,F7,F82 $(python_sources)
else
    bad "ruff is required: brew install ruff"
fi

# --- 3. every suite ----------------------------------------------------------
step "tests"
check "make test (every suite)" ./scripts/test.sh

# --- 4. the real build -------------------------------------------------------
step "build"
if [ "${MASH_PREFLIGHT_SKIP_BUILD:-}" = 1 ]; then
    bad "build skipped (MASH_PREFLIGHT_SKIP_BUILD=1); this tree is not proven"
elif [ "$(uname -s)" != Darwin ]; then
    bad "the release build is the macOS one; run this on a Mac"
else
    log="$root/dist/release-preflight-build.log"
    mkdir -p "$root/dist"
    if ./packaging/build.sh >"$log" 2>&1; then
        app="$root/dist/Mash.app"
        version="$(tr -d '[:space:]' <VERSION)"
        built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$built" != "$version" ]; then
            bad "dist/Mash.app reports '$built', expected $version"
        elif ! codesign --verify --deep --strict "$app" 2>/dev/null; then
            bad "dist/Mash.app does not pass codesign --verify --deep --strict"
        else
            ok "dist/Mash.app $built built and verifies ($log)"
            check "Fresh park/reattach on a PTY" python3 packaging/tests/fresh-park-pty.py \
                "$app/Contents/Resources/libexec/fresh"
        fi
    else
        bad "packaging/build.sh failed; full log: $log"
        tail -25 "$log" | sed 's/^/        /'
    fi
fi

elapsed=$(($(date +%s) - started))
echo
if [ "$failures" -eq 0 ]; then
    printf 'release-preflight: PASSED in %dm%02ds\n' $((elapsed / 60)) $((elapsed % 60))
    exit 0
fi
printf 'release-preflight: FAILED (%d problem(s)) after %dm%02ds\n' "$failures" $((elapsed / 60)) $((elapsed % 60))
exit 1
