#!/bin/bash
# Shared counters for shell suites using check MESSAGE COMMAND [ARGS...].
pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() {
  local msg="$1"
  shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}
