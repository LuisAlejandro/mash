#!/usr/bin/env bash
# Mash's `pi` shim animates the wait and still ends at the real agent.
#
# The order is what matters: the animation must never become the pane's
# foreground process, because Herdr accepts Pi's state reports only while Pi
# holds that place. So every case here ends by exec'ing the real binary.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
helper="$root/packaging/helpers/pi"
[ -x "$helper" ] || {
  echo "the pi shim is missing or not executable" >&2
  exit 1
}
for name in pi mash-pane-spin mash-pane-starting; do
  grep -qx "  $name" "$root/packaging/build.sh" || {
    echo "macOS build does not ship $name" >&2
    exit 1
  }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/node/bin"
cp "$helper" "$tmp/bin/pi"
chmod +x "$tmp/bin/pi"

# A stand-in for the bundled pi.
cat >"$tmp/node/bin/pi" <<'SH'
#!/bin/sh
printf 'REAL argv=%s active=%s\n' "$*" "${MASH_PI_SHIM_ACTIVE:-unset}"
SH
chmod +x "$tmp/node/bin/pi"

# Stand-ins for the two helpers the shim uses, recording that they ran.
for name in mash-pane-spin mash-pane-starting; do
  cat >"$tmp/bin/$name" <<SH
#!/bin/sh
printf '%s %s\n' "$name" "\$*" >>"$tmp/helpers.log"
if [ "$name" = mash-pane-starting ]; then printf 'Starting the agent...'; fi
SH
  chmod +x "$tmp/bin/$name"
done

run() {
  : >"$tmp/helpers.log"
  MASH_BIN="$tmp/bin:$tmp/node/bin" PATH="/usr/bin:/bin" "$tmp/bin/pi" "$@"
}

# --- it resolves the real agent from a later MASH_BIN entry ---------------
out="$(run --session /s.jsonl)"
[ "$out" = "REAL argv=--session /s.jsonl active=1" ] || {
  echo "the shim did not reach the real pi: $out" >&2
  exit 1
}

# --- a piped run starts no animation ------------------------------------
# No terminal means nothing to draw on and nothing to read back.
[ ! -s "$tmp/helpers.log" ] || {
  echo "a piped run started helpers: $(cat "$tmp/helpers.log")" >&2
  exit 1
}

# --- the guard stops a second shim from wrapping again ------------------
out="$(MASH_PI_SHIM_ACTIVE=1 MASH_BIN="$tmp/bin:$tmp/node/bin" PATH="/usr/bin:/bin" "$tmp/bin/pi" --version)"
[ "$out" = "REAL argv=--version active=1" ] || {
  echo "the guard did not bypass the shim: $out" >&2
  exit 1
}

# --- with no bundled pi it fails closed --------------------------------
status=0
MASH_BIN="$tmp/bin" PATH="/usr/bin:/bin" "$tmp/bin/pi" 2>"$tmp/err" || status=$?
[ "$status" = 127 ] || {
  echo "a missing bundled pi did not fail (exit $status)" >&2
  exit 1
}
grep -q 'does not ship pi' "$tmp/err" || {
  echo "a missing bundled pi was not explained: $(cat "$tmp/err")" >&2
  exit 1
}

echo "pi shim: ok"
