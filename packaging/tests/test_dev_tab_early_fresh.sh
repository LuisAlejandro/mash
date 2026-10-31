#!/usr/bin/env bash
# Scripted tabs start Fresh before shell startup; the native "+" hook still
# sends its command to an already-created shell. Both keep tracked pi.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work space"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/pi"
chmod +x "$tmp/bin/pi"

cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf '<%s>' "$@" >>"$HERDR_STUB_LOG"
printf '\n' >>"$HERDR_STUB_LOG"
case "$1 $2" in
  'tab create') printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"w1:p2","workspace_id":"w1","cwd":"%s"}}}\n' "$HERDR_STUB_CWD" ;;
  'pane split') printf '{"result":{"pane":{"pane_id":"w1:p3"}}}\n' ;;
  'workspace list') printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"demo"}]}}\n' ;;
  'agent list') printf '{"result":{"agents":[]}}\n' ;;
esac
EOF
chmod +x "$tmp/bin/herdr"
export HERDR_BIN_PATH="$tmp/bin/herdr" HERDR_STUB_LOG="$tmp/calls" \
  HERDR_STUB_CWD="$tmp/work space" MASH_BIN="$tmp/bin" \
  HERDR_ACTIVE_PANE_CWD="$tmp/work space" HERDR_ACTIVE_WORKSPACE_ID=w1

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
"$root/helpers/herdr-new-dev-tab"
grep -Fqx '<tab><create><--label><herdr-tab-launcher-dev><--workspace><w1><--cwd><'"$tmp/work space"'><--env><MASH_DEV_TAB_FRESH=1><--focus>' "$HERDR_STUB_LOG" || fail 'tab did not pass early Fresh env'
if grep -Fq '<pane><run><w1:p2>' "$HERDR_STUB_LOG"; then
  fail 'scripted tab typed Fresh into its shell'
fi
grep -Fq '<agent><start><demo-pi><--kind><pi><--pane><w1:p3>' "$HERDR_STUB_LOG" || fail 'scripted tab lost tracked pi'

: >"$HERDR_STUB_LOG"
"$root/helpers/herdr-dev-tab-fill" w1:p2
grep -Fqx '<pane><run><w1:p2><herdr-fresh-pane .>' "$HERDR_STUB_LOG" || fail 'native + hook no longer starts Fresh'
grep -Fq '<agent><start><demo-pi><--kind><pi><--pane><w1:p3>' "$HERDR_STUB_LOG" || fail 'native + hook lost tracked pi'
printf 'dev tab early Fresh: ok\n'
