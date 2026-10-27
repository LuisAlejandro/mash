#!/bin/bash
# The destructive boundary: all checks use throwaway .app directories only.
# macOS also compiles and executes the real RENAME_SWAP helper against them.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$name"
    fail=$((fail + 1))
  fi
}

tools="$tmp/tools"
mkdir -p "$tools"
for t in bash cat mkdir rm mv dirname basename sed grep awk ps kill sleep cp chmod mktemp seq diff; do
  ln -s "$(command -v "$t")" "$tools/$t"
done
fake="$tmp/fake"
mkdir -p "$fake"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$fake/$1"
  chmod +x "$fake/$1"
}
stub ditto 'echo "ditto $*" >>"$CALLS"
[ "${FAKE_DITTO_RC:-0}" = 0 ] || exit "$FAKE_DITTO_RC"
cp -R "$1" "$2"'
stub osascript 'echo "osascript $*" >>"$CALLS"; exit 0'
stub open 'echo "open $*" >>"$CALLS"'
stub ps 'if [ "${FAKE_STUCK:-0}" = 1 ]; then
  echo "999999 $FAKE_DEST/Contents/Resources/bin/herdr"
fi'
stub kill ':'
stub sleep ':'
stub herdr ':'
stub codesign 'echo "codesign $*" >>"$CALLS"'
stub spctl 'echo "spctl $*" >>"$CALLS"'

if [ "$(uname -s)" = Darwin ]; then
  xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
    -o "$tmp/real-swap" "$root/packaging/helpers/mash-update-swap.c" || exit 1
  # Direct native exchange proof: complete directories before and after;
  # no two-rename sequence is present in the native helper.
  mkdir -p "$tmp/native/installed/Mash.app" "$tmp/native/installed/staged.app"
  echo old >"$tmp/native/installed/Mash.app/marker"
  echo new >"$tmp/native/installed/staged.app/marker"
  "$tmp/real-swap" "$tmp/native/installed/staged.app" "$tmp/native/installed/Mash.app"
  check "native exchange installs new app" grep -qx new "$tmp/native/installed/Mash.app/marker"
  check "native exchange keeps old app at sibling" grep -qx old "$tmp/native/installed/staged.app/marker"
  "$tmp/real-swap" "$tmp/native/installed/staged.app" "$tmp/native/installed/Mash.app"
  check "native exchange reverses without losing app" grep -qx old "$tmp/native/installed/Mash.app/marker"
else
  # Ubuntu CI cannot compile a macOS syscall; the installed-build checklist
  # exercises it on macOS. Only the shell orchestration is checked here.
  printf '#!/bin/bash\n[ "${FAKE_SWAP_RC:-0}" = 0 ] || exit "$FAKE_SWAP_RC"\nt="${1}.temp"; mv "$1" "$t"; mv "$2" "$1"; mv "$t" "$2"\n' >"$tmp/real-swap"
  chmod +x "$tmp/real-swap"
fi

calls="$tmp/calls"
dest="$tmp/Applications/Mash.app"
data="$tmp/data"

reset() {
  rm -rf "$tmp/Applications" "$tmp/mash-update-ABCDEF" "$tmp/data" "$tmp/user-owned-before"
  mkdir -p "$dest/Contents" "$tmp/mash-update-ABCDEF/Mash.app/Contents" \
    "$data/local/state" "$data/workspaces/project" "$data/config/mash" "$data/config/gh"
  echo old >"$dest/Contents/marker"
  echo new >"$tmp/mash-update-ABCDEF/Mash.app/Contents/marker"
  echo 0.2.0 >"$data/local/state/update-notice"
  echo 0.2.0 >"$data/local/state/update-pending"
  echo 'unsaved task context' >"$data/workspaces/project/session.txt"
  echo 'user edit' >"$data/config/mash/user-settings"
  echo 'credential placeholder (not a secret)' >"$data/config/gh/hosts.yml"
  mkdir -p "$tmp/user-owned-before"
  cp -R "$data/workspaces" "$data/config" "$tmp/user-owned-before/"
  : >"$calls"
  work="$tmp/mash-update-ABCDEF"
  cp "$tmp/real-swap" "$work/mash-update-swap"
}
run() {
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_DEST="$dest" "$@" \
    bash "$root/packaging/helpers/mash-update-apply" \
    --app "$work/Mash.app" --dest "$dest" --data "$data" --work "$work" --version 0.2.0 \
    >"$tmp/out" 2>"$tmp/err"
}

reset
run
check "the destination contains the new app" grep -qx new "$dest/Contents/marker"
check "success reopens Mash" grep -q "^open $dest" "$calls"
check "success records version for first new window" grep -qx 0.2.0 "$data/local/state/update-success"
check "success consumes the pending marker" test ! -e "$data/local/state/update-pending"
check "success leaves no sibling copy" test -z "$(find "$tmp/Applications" -maxdepth 1 -name '.mash-update-*' -print)"
check "success leaves user-owned files untouched" \
  diff -rq "$data/workspaces" "$tmp/user-owned-before/workspaces"
check "success leaves user edits untouched" \
  diff -rq "$data/config" "$tmp/user-owned-before/config"
check "success preserves the announcement record" grep -qx 0.2.0 "$data/local/state/update-notice"

reset
run FAKE_DITTO_RC=4
check "copy failure keeps old app" grep -qx old "$dest/Contents/marker"
check "copy failure does not reopen" test ! -s "$tmp/out"
check "copy failure clears record" test ! -e "$data/local/state/update-notice"
check "copy failure marks this version for retry" grep -qx 0.2.0 "$data/local/state/update-retry"
check "copy failure clears pending state" test ! -e "$data/local/state/update-pending"
check "copy failure notifies" grep -q 'osascript .*display notification' "$calls"
check "copy failure keeps user-owned files" \
  diff -rq "$data/workspaces" "$tmp/user-owned-before/workspaces"

reset
# An executable that refuses the exchange simulates unsupported filesystems.
printf '#!/bin/bash\nexit 1\n' >"$work/mash-update-swap"
chmod +x "$work/mash-update-swap"
run
check "swap refusal keeps old app" grep -qx old "$dest/Contents/marker"
check "swap refusal clears record" test ! -e "$data/local/state/update-notice"
check "swap refusal notifies" grep -q 'osascript .*display notification' "$calls"
check "swap refusal keeps user edits" \
  diff -rq "$data/config" "$tmp/user-owned-before/config"

reset
run FAKE_STUCK=1
check "unexited processes keep old app" grep -qx old "$dest/Contents/marker"
check "unexited processes prevent copy" test "$(grep -c '^ditto ' "$calls")" = 0
check "unexited processes clear record" test ! -e "$data/local/state/update-notice"

reset
# Malformed paths must never lead to a move or delete.
env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" bash \
  "$root/packaging/helpers/mash-update-apply" --app "$work/Mash.app" \
  --dest "$tmp/Applications/not-an-app" --data "$data" --work "$work" \
  >"$tmp/out" 2>"$tmp/err"
check "non-app destination never moved" grep -qx old "$dest/Contents/marker"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
