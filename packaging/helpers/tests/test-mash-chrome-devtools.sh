#!/usr/bin/env bash
# mash-chrome-devtools runs the pinned Chrome DevTools command line tool.
#
# It replaces a session-long MCP server, so the behaviour that matters is what
# a session pays for and what one agent can do to another:
#
#   * an installed tool is exec'd directly -- no `npx`, no resolver wrapper
#     left resident behind it for the session
#   * the first diagnostic installs the package from the manifest pin, through
#     mash-tool-install, and only then runs it
#   * contention with another session's install waits for the tool instead of
#     reporting it missing over a lock
#   * a real install failure is reported once, not retried for a minute
#   * each Pi session gets its own background server, so one agent's `start`
#     cannot discard the pages another agent is reading
#   * outside a Mash session it says so instead of guessing a data folder
#
# A fake installer stands in for npm, so this runs anywhere. The real installer
# is covered by test-mash-tool-install.sh.
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/mash-chrome-devtools"
[ -x "$helper" ] || {
  echo "mash-chrome-devtools is missing or not executable" >&2
  exit 1
}
# An unshipped helper never reaches a session.
grep -qx '  mash-chrome-devtools' "$(dirname "$helper")/../build.sh" || {
  echo "macOS build does not ship mash-chrome-devtools" >&2
  exit 1
}
# The wrapper exists to keep both `npx` and a session-long server out of the
# session: a resolver in front of the tool is the cost it was written to stop
# paying.
if grep -n 'npx' "$helper" | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
  echo "mash-chrome-devtools still names npx in code" >&2
  exit 1
fi
# Configuring it as an MCP server is what made it resident in every session.
if grep -q '"chrome-devtools":' "$(dirname "$helper")/../carry.sh"; then
  echo "carry.sh configures chrome-devtools as an MCP server again" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
res="$tmp/res"
data="$tmp/home/.mash"
mkdir -p "$res/bin" "$data/setup" "$res/node/bin"
cp "$helper" "$res/bin/mash-chrome-devtools"
chmod +x "$res/bin/mash-chrome-devtools"

# A stand-in installer: records every component it was asked for and creates the
# npm shim, which is what the real one leaves behind. `MASH_FAKE_INSTALL` picks
# the outcome -- ok, lock (another run holds the lock, then succeeds), or fail.
# The fake tool reports the session id so its scoping can be asserted.
cat >"$res/bin/mash-tool-install" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$MASH_DATA_DIR/asked"
install_tool() {
  mkdir -p "$MASH_DATA_DIR/local/npm/bin"
  printf '#!/bin/sh\nprintf "tool %%s session=%%s\\n" "$*" "${CD4A_INTERNAL_DAEMON_SESSION_ID:-none}"\n' \
    >"$MASH_DATA_DIR/local/npm/bin/chrome-devtools"
  chmod 755 "$MASH_DATA_DIR/local/npm/bin/chrome-devtools"
}
case "${MASH_FAKE_INSTALL:-ok}" in
ok) install_tool ;;
lock)
  # The first call reports contention; the lock is gone by the second.
  if [ ! -f "$MASH_DATA_DIR/locked-once" ]; then
    : >"$MASH_DATA_DIR/locked-once"
    mkdir -p "$MASH_DATA_DIR/setup/tool-install.lock"
    (sleep 1; rmdir "$MASH_DATA_DIR/setup/tool-install.lock"; : >"$MASH_DATA_DIR/lock-released") &
    exit 1
  fi
  install_tool
  ;;
fail) exit 1 ;;
esac
SH
chmod +x "$res/bin/mash-tool-install"

# `env -i` on purpose: this process runs inside a Pi session of its own, and an
# inherited PI_SESSION_ID would make the unscoped cases look scoped.
run() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin MASH_DATA_DIR="$data" \
    MASH_FAKE_INSTALL="${MASH_FAKE_INSTALL:-ok}" PI_SESSION_ID="${SESSION:-}" \
    "$res/bin/mash-chrome-devtools" lighthouse_audit 2
}

asked() {
  [ -f "$data/asked" ] || return 0
  cat "$data/asked"
}

reset() {
  rm -rf "$data/local" "$data/asked" "$data/locked-once" "$data/lock-released"
}

# --- already installed: run it, install nothing ------------------------------
mkdir -p "$data/local/npm/bin"
printf '#!/bin/sh\nprintf "tool %%s session=%%s\\n" "$*" "${CD4A_INTERNAL_DAEMON_SESSION_ID:-none}"\n' \
  >"$data/local/npm/bin/chrome-devtools"
chmod 755 "$data/local/npm/bin/chrome-devtools"
out="$(run)"
[ "$out" = "tool lighthouse_audit 2 session=none" ] || {
  echo "an installed tool did not pass its arguments through: $out" >&2
  exit 1
}
[ -z "$(asked)" ] || {
  echo "an installed tool was reinstalled: $(asked)" >&2
  exit 1
}

# --- a Pi session gets its own server ---------------------------------------
first="$(SESSION=3f1a6c20-0000-4000-8000-000000000001 run)"
second="$(SESSION=3f1a6c20-0000-4000-8000-000000000002 run)"
first_id="${first##*session=}"
second_id="${second##*session=}"
[ -n "$first_id" ] && [ "$first_id" != none ] || {
  echo "a Pi session did not scope the server: $first" >&2
  exit 1
}
[ "$first_id" != "$second_id" ] || {
  echo "two Pi sessions shared one server id ($first_id)" >&2
  exit 1
}
# The same session must reach the same server, or start and stop cannot pair up.
again="$(SESSION=3f1a6c20-0000-4000-8000-000000000001 run)"
[ "${again##*session=}" = "$first_id" ] || {
  echo "one session produced two server ids: $first_id then ${again##*session=}" >&2
  exit 1
}
# Only hex digits and dashes are accepted by the tool.
case "$first_id" in
*[!0-9a-fA-F-]*)
  echo "the server id is not a valid session id: $first_id" >&2
  exit 1
  ;;
esac

# --- missing: install from the pin, then run --------------------------------
reset
out="$(run)"
[ "$out" = "tool lighthouse_audit 2 session=none" ] || {
  echo "the installed tool did not run: $out" >&2
  exit 1
}
[ "$(asked)" = "chrome-devtools-mcp" ] || {
  echo "the wrapper did not ask mash-tool-install for chrome-devtools-mcp: $(asked)" >&2
  exit 1
}

# --- another session holds the install lock: wait, then run -----------------
reset
MASH_FAKE_INSTALL=lock out="$(run)"
[ "$out" = "tool lighthouse_audit 2 session=none" ] || {
  echo "a concurrent install failed this session's diagnostic: $out" >&2
  exit 1
}
[ -f "$data/lock-released" ] || {
  echo "the wrapper never waited for the other install to finish" >&2
  exit 1
}

# --- a real failure is reported, not retried --------------------------------
reset
status=0
MASH_FAKE_INSTALL=fail run >"$tmp/out" 2>"$tmp/err" || status=$?
[ "$status" = 1 ] || {
  echo "a failed install did not fail the wrapper (exit $status)" >&2
  exit 1
}
grep -q 'chrome-devtools-mcp is not installed' "$tmp/err" || {
  echo "a failed install did not say so: $(cat "$tmp/err")" >&2
  exit 1
}
[ "$(asked)" = "chrome-devtools-mcp" ] || {
  echo "a failed install was retried: $(asked)" >&2
  exit 1
}

# --- outside a Mash session -------------------------------------------------
status=0
env -i HOME="$tmp/home" PATH=/usr/bin:/bin "$res/bin/mash-chrome-devtools" status \
  >"$tmp/out" 2>"$tmp/err" || status=$?
[ "$status" = 1 ] || {
  echo "the wrapper guessed a data folder outside a Mash session (exit $status)" >&2
  exit 1
}
grep -q 'not in a Mash session' "$tmp/err" || {
  echo "the wrapper did not name the missing session: $(cat "$tmp/err")" >&2
  exit 1
}

echo "mash-chrome-devtools: ok"
