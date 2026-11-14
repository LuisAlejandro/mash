#!/bin/bash
# herdr-fork-pi against a recording fake herdr: the Herdr half of a fork chord.
#
# The Pi half (selector, fork, cleanup) is test_fork_from_message.mjs. What is
# checked here is what this script alone decides:
#   - only a tracked Pi pane with a saved session is forked, and a refused
#     pane creates nothing
#   - Pi starts in the new pane with `--fork <source>` and the destination to
#     close on cancel, never in the source pane
#   - Pi's pane is NOT the quiet startup shell (MASH_PANE_STARTUP=agent): its
#     grace timer holds the pane busy for a minute, see herdr-fork-pi
#   - a busy pane is retried; a start that never succeeds closes the destination
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/bin"
mkdir -p "$bin"
cp "$root/packaging/helpers/herdr-fork-pi" "$root/packaging/helpers/herdr-json" "$bin/"
py="$(python3 -c 'import sys; print(sys.executable)')"
printf '#!/bin/sh\n[ "$1" = python3 ] && { echo %s; exit 0; }\nexit 1\n' "$py" >"$bin/mash-bin"
printf '#!/bin/sh\necho pi-agent\n' >"$bin/herdr-agent-name"
session="$tmp/source.jsonl"
echo '{"type":"session"}' >"$session"
mkdir -p "$tmp/agent/extensions"
: >"$tmp/agent/extensions/fork-from-message.ts"
export PI_CODING_AGENT_DIR="$tmp/agent"

# The fake answers the calls herdr-fork-pi makes, logs every one, and fails
# `agent start` BUSY_STARTS times with agent_pane_busy before succeeding.
cat >"$bin/herdr" <<EOF
#!/bin/sh
echo "\$*" >>"$tmp/calls"
case "\$1 \$2" in
"pane get")
  if [ "\$3" = w1:p1 ]; then
    agent=\${SOURCE_AGENT-pi}
    printf '{"result":{"pane":{"pane_id":"w1:p1","agent":"%s","workspace_id":"w1","cwd":"$tmp","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"%s"}}}}' "\$agent" "\${SOURCE_SESSION-$session}"
  else
    printf '{"result":{"pane":{"pane_id":"%s","workspace_id":"w1","cwd":"$tmp"}}}' "\$3"
  fi ;;
"tab create") echo '{"result":{"tab":{"tab_id":"w1:t5"},"root_pane":{"pane_id":"w1:p8"}}}' ;;
"pane split") echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
"pane layout") echo '{"result":{"layout":{"panes":[{"pane_id":"w1:p1","rect":{"width":200,"height":50}}]}}}' ;;
"workspace create") echo '{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t1"},"root_pane":{"pane_id":"w7:p1"}}}' ;;
"agent start")
  n=\$(grep -c '^agent start' "$tmp/calls")
  if [ "\$n" -le "\${BUSY_STARTS:-0}" ]; then
    echo '{"error":{"code":"agent_pane_busy"}}'
    exit 1
  fi ;;
esac
exit 0
EOF
chmod +x "$bin"/*

fork() {
  : >"$tmp/calls"
  HERDR_BIN_PATH="$bin/herdr" HERDR_ACTIVE_PANE_ID=w1:p1 MASH_FORK_RETRY_DELAY=0 "$@"
}
fail() {
  echo "FAIL: $1" >&2
  sed 's/^/  /' "$tmp/calls" >&2
  exit 1
}

# --- a tab: the cmd+t layout, Pi forked into the right-hand pane ------------
fork sh "$bin/herdr-fork-pi" tab || fail "tab fork exited non-zero"
grep -q '^tab create .*--env MASH_DEV_TAB_FRESH=1' "$tmp/calls" || fail "the tab does not start Fresh"
grep -q '^pane split w1:p8 --direction right' "$tmp/calls" || fail "Pi's pane is not split off Fresh"
grep -q "^agent start pi-agent --kind pi --pane w1:p9 .* -- --session-dir $tmp --fork $session --mash-fork-into tab:w1:t5 /mash-fork\$" "$tmp/calls" ||
  fail "Pi is not started with --fork, beside its source, and the tab to close"
grep -q 'MASH_PANE_STARTUP' "$tmp/calls" && fail "a pane got the quiet startup shell"
grep -q '^agent focus pi-agent' "$tmp/calls" || fail "Pi is not focused once ready"
grep -q 'w1:p1 .*close\|close w1:p1\|agent start .*--pane w1:p1' "$tmp/calls" && fail "the source pane was touched"

# --- a split beside the source, and a workspace ------------------------------
fork sh "$bin/herdr-fork-pi" pane || fail "pane fork exited non-zero"
grep -q '^pane split w1:p1 --direction right' "$tmp/calls" || fail "a wide pane is not split beside"
grep -q -- '--mash-fork-into pane:w1:p9 /mash-fork$' "$tmp/calls" || fail "the split is not the destination"
fork sh "$bin/herdr-fork-pi" workspace || fail "workspace fork exited non-zero"
grep -q -- '--pane w7:p1 .*--mash-fork-into workspace:w7 /mash-fork$' "$tmp/calls" || fail "the workspace is not the destination"
grep -q '^workspace focus w7' "$tmp/calls" || fail "the new workspace is not focused"

# --- a pane that is still starting is retried --------------------------------
BUSY_STARTS=3 fork sh "$bin/herdr-fork-pi" tab || fail "a briefly busy pane was not retried"
[ "$(grep -c '^agent start' "$tmp/calls")" = 4 ] || fail "expected three busy tries and one start"

# --- refusals create nothing --------------------------------------------------
for refusal in "SOURCE_AGENT=fresh" "SOURCE_SESSION=$tmp/missing.jsonl" "SOURCE_SESSION=relative.jsonl"; do
  if env "$refusal" HERDR_BIN_PATH="$bin/herdr" HERDR_ACTIVE_PANE_ID=w1:p1 sh -c ': >"$1"; sh "$2" tab' _ "$tmp/calls" "$bin/herdr-fork-pi" 2>/dev/null; then
    fail "$refusal was forked"
  fi
  grep -q '^tab create\|^pane split\|^workspace create' "$tmp/calls" && fail "$refusal created a destination"
done

# --- without the extension Pi would exit after --fork wrote its copy -------
rm "$tmp/agent/extensions/fork-from-message.ts"
if fork sh "$bin/herdr-fork-pi" tab 2>/dev/null; then fail "forked with the extension missing"; fi
grep -q '^tab create\|^agent start' "$tmp/calls" && fail "the missing extension was found only after creating a tab"
: >"$tmp/agent/extensions/fork-from-message.ts"

# --- a start that never succeeds closes the destination ----------------------
if BUSY_STARTS=1000 fork sh "$bin/herdr-fork-pi" tab 2>/dev/null; then
  fail "a pane that never frees up reported success"
fi
grep -q '^tab close w1:t5' "$tmp/calls" || fail "the half-made tab was left open"
grep -q '^pane run' "$tmp/calls" && fail "fell back to typing the session into a shell"

echo "herdr-fork-pi: ok"
