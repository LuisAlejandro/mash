#!/bin/bash
# Run every test this repository ships, on any platform that can host them.
#
# The same script backs `make test`, the push gate and the release matrix, so a
# test cannot pass in one place and be skipped in another. Platform-specific
# suites are listed where they are, not hidden behind a skip that reports green.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

failed=0
ran=0
skipped=()

run() {
  local label="$1"
  shift
  ran=$((ran + 1))
  if "$@"; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label"
    failed=1
  fi
}

# Rust: the wizard and its page logic.
command -v cargo >/dev/null 2>&1 &&
  run "wizard (cargo test)" cargo test --locked --manifest-path packaging/wizard/Cargo.toml --quiet ||
  skipped+=("wizard: cargo not installed")

# Python: packaging contracts, templates and helper behaviour.
while IFS= read -r test_file; do
  run "$test_file" python3 "$test_file"
done < <(find packaging/tests -maxdepth 1 -name 'test_*.py' | sort)

# Shell: the launcher, isolation and helpers. Both directories are globbed, so
# a new suite is picked up by being added, not by being listed here. This also
# runs the voice-model and tool-install suites added on develop.
while IFS= read -r test_file; do
  run "$test_file" bash "$test_file"
done < <(find packaging/helpers/tests -maxdepth 1 -name 'test-*.sh' | sort)
while IFS= read -r test_file; do
  # A build gate, not a suite: it needs a resource root, and the build runs it
  # against the staged bundle (build.sh, build-common.sh).
  [ "$test_file" = "packaging/tests/test_pi_runtime.sh" ] && continue
  run "$test_file" bash "$test_file"
done < <(find packaging/tests -maxdepth 1 -name 'test_*.sh' | sort)

# Node: the Pi extensions the product ships.
if command -v node >/dev/null 2>&1; then
  for extension_test in packaging/tests/test_*.mjs; do
    [ -f "$extension_test" ] || continue
    run "$extension_test" node "$extension_test"
  done
else
  skipped+=("extension tests: node not installed")
fi

# Mash's own plugin: Herdr's `pane run` prints nothing on success, and the
# fork-from-message code has to stay that way or the fork tab breaks.
run "packaging/plugins/fork-from-message/tests/test_fork_from_message.py" \
  python3 packaging/plugins/fork-from-message/tests/test_fork_from_message.py

# Mash's own orchestration loop: renamed CLI and state are part of this repo.
run "packaging/plugins/mash-orchestration/tests/test_orchestration.py" \
  python3 packaging/plugins/mash-orchestration/tests/test_orchestration.py

# Other vendored plugins are not run here. They are other projects' code with
# their own upstream CI, and scripts/preflight.sh already excludes
# packaging/plugins from its parsing for the same reason: their failures are
# not this repo's.

echo
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'skipped: %s\n' "$(IFS='; '; echo "${skipped[*]}")"
fi
if [ "$failed" -ne 0 ]; then
  printf 'test: FAILED (%d suite(s) ran)\n' "$ran"
  exit 1
fi
printf 'test: PASSED (%d suite(s) ran)\n' "$ran"
