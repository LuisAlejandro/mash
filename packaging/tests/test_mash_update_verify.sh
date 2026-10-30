#!/bin/bash
# What has to be true before Mash quits to replace itself.
#
# The point of this file is the refusals. A download that is not ours, or not
# notarized, or signed by somebody else, must never reach the swap helper --
# and no path may leave a mounted image or a downloaded file behind.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok() {
  printf 'ok   - %s\n' "$1"
  pass=$((pass + 1))
}
nok() {
  printf 'FAIL - %s\n' "$1"
  fail=$((fail + 1))
}
check() { # check MSG CMD... -- record a pass when CMD succeeds
  local msg="$1"
  shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}

# Stage stand-ins for the three helpers in the same bin directory. The real
# native swap executable is tested separately by U5; the verify test only
# checks that it is copied out for the detached process.
res="$tmp/res/bin"
mkdir -p "$res"
cp "$root/packaging/helpers/mash-update-verify" "$res/"
cp "$root/packaging/helpers/mash-update-apply" "$res/"
printf '#!/bin/bash\nexit 0\n' >"$res/mash-update-swap"
chmod +x "$res/mash-update-swap"
helper="$res/mash-update-verify"
calls="$tmp/calls"

tools="$tmp/tools"
mkdir -p "$tools"
for t in bash cat mkdir rm mv rmdir sed head tail grep awk ls dirname basename chmod sleep mktemp cp; do
  ln -s "$(command -v "$t")" "$tools/$t"
done

fake="$tmp/fake"
mkdir -p "$fake"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$fake/$1"
  chmod +x "$fake/$1"
}

# A mount that produces a stand-in Mash.app, so the helper has something to
# verify and to stage.
stub hdiutil 'echo "hdiutil $*" >>"$CALLS"
case "$1" in
attach)
  [ "${FAKE_MOUNT_RC:-0}" = 0 ] || exit "$FAKE_MOUNT_RC"
  prev=""
  for a in "$@"; do [ "$prev" = -mountpoint ] && mnt="$a"; prev="$a"; done
  mkdir -p "$mnt/Mash.app/Contents"
  echo new >"$mnt/Mash.app/Contents/marker"
  mkdir -p "$mnt/Mash.app/Contents/Resources"
  echo "${FAKE_ASSET_VERSION:-0.2.0}" >"$mnt/Mash.app/Contents/Resources/VERSION"
  ;;
detach) rm -rf "$2" ;;
esac'
stub curl 'echo "curl $*" >>"$CALLS"
[ "${FAKE_DOWNLOAD_RC:-0}" = 0 ] || exit "$FAKE_DOWNLOAD_RC"
prev=""
for a in "$@"; do [ "$prev" = -o ] && echo dmg >"$a"; prev="$a"; done'
stub codesign 'echo "codesign $*" >>"$CALLS"
case "$1" in
--verify) exit "${FAKE_CODESIGN_RC:-0}" ;;
-dv|-dvv)
  # The running bundle is ours; the downloaded one is whatever the case sets.
  case "$*" in
  *"$FAKE_RUNNING_APP"*) echo "TeamIdentifier=4SCJW6LZ6T" >&2 ;;
  *) echo "TeamIdentifier=${FAKE_TEAM:-4SCJW6LZ6T}" >&2 ;;
  esac
  ;;
esac'
stub spctl 'echo "spctl $*" >>"$CALLS"; exit "${FAKE_SPCTL_RC:-0}"'
stub xattr 'echo "xattr $*" >>"$CALLS"'
stub ditto 'echo "ditto $*" >>"$CALLS"
mkdir -p "$2" && cp -R "$1/." "$2/" 2>/dev/null; exit 0'
stub nohup 'echo "apply $*" >>"$CALLS"
prev=""
for a in "$@"; do [ "$prev" = --work ] && rm -rf "$a"; prev="$a"; done'
stub pgrep 'exit 1'

running="$tmp/Applications/Mash.app"
mkdir -p "$running/Contents/Resources/bin"
echo old >"$running/Contents/marker"
data="$tmp/data"
mkdir -p "$data/local/state"

reset() { # reset [KEY] -- a clean run, with the version already announced
  : >"$calls"
  rm -rf "$tmp/mnt" "$tmp/stage"
  printf '0.2.0\n' >"$data/local/state/update-notice"
  rm -f "$data/local/state/update-pending" "$data/local/state/update-retry"
  answer="${1:-y}"
}

run() { # run [VAR=value...] -- one verify+handoff, answering the confirmation
  printf '%s\n' "$answer" | env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" \
    FAKE_MNT="$tmp/mnt" FAKE_RUNNING_APP="$running" TMPDIR="$tmp" "$@" \
    bash "$helper" "$running" 0.2.0 0.1.1 "$data" >"$tmp/out" 2>"$tmp/err"
  # The helper hands off with `nohup ... &` and exits, so the stub logs after
  # the helper returns. A fixed sleep had to guess how long that takes: too
  # short and the happy path saw no handoff, and the late write then landed in
  # the *next* scenario's log and failed that one too.
  #
  # The helper announces the handoff on its last line, so that is the signal for
  # whether a write is still coming. A refusal never prints it and must not hand
  # off at all, so a short grace period is enough to let a stray write surface
  # here rather than inside the next scenario.
  if grep -q 'Installing' "$tmp/out"; then
    wait_for_apply
  else
    sleep 0.3
  fi
  return 0
}

# Up to ~10s for the backgrounded stub to log the handoff it promised.
wait_for_apply() {
  local attempt
  for attempt in $(seq 1 100); do
    [ "$(applied)" -ge 1 ] && return 0
    sleep 0.1
  done
  return 1
}
count() { grep -c "^$1 " "$calls" 2>/dev/null || true; }
applied() { grep -c "apply " "$calls" 2>/dev/null || true; }

# --- the happy path -------------------------------------------------------------
reset
run
check "the DMG is downloaded" test "$(count curl)" -ge 1
check "the download names the release asset" \
  grep -q 'curl .*releases/download/0\.2\.0/Mash-0\.2\.0-mac-arm64\.dmg' "$calls"
check "the image is mounted" grep -q 'hdiutil attach' "$calls"
check "the signature is verified" grep -q 'codesign --verify' "$calls"
check "Gatekeeper is asked" grep -q 'spctl --assess' "$calls"
check "the swap helper is started" test "$(applied)" = 1
check "pending version is recorded for crash recovery" grep -qx 0.2.0 "$data/local/state/update-pending"
check "the image is detached" grep -q 'hdiutil detach' "$calls"
check "the record still holds the version" grep -qx 0.2.0 "$data/local/state/update-notice"

# --- a wrong Team ID is the refusal that matters --------------------------------
reset
run FAKE_TEAM=XXXXXXXXXX
check "a foreign Team ID does not reach the swap" test "$(applied)" = 0
check "a foreign Team ID is explained" grep -qi 'team' "$tmp/out"
check "a foreign Team ID detaches the image" grep -q 'hdiutil detach' "$calls"
check "a foreign Team ID clears the record" test ! -e "$data/local/state/update-notice"
check "a failed update is eligible again without another request" grep -qx 0.2.0 "$data/local/state/update-retry"
check "a foreign Team ID leaves the app alone" grep -qx old "$running/Contents/marker"

# --- a bad signature stops before Gatekeeper ------------------------------------
reset
run FAKE_CODESIGN_RC=1
check "a bad signature does not reach the swap" test "$(applied)" = 0
check "a bad signature skips the Gatekeeper call" test "$(count spctl)" = 0
check "a bad signature detaches the image" grep -q 'hdiutil detach' "$calls"
check "a bad signature clears the record" test ! -e "$data/local/state/update-notice"

# --- Gatekeeper refuses ----------------------------------------------------------
reset
run FAKE_SPCTL_RC=3
check "a Gatekeeper refusal does not reach the swap" test "$(applied)" = 0
check "a Gatekeeper refusal detaches the image" grep -q 'hdiutil detach' "$calls"
check "a Gatekeeper refusal clears the record" test ! -e "$data/local/state/update-notice"

# --- a correctly signed but wrong-version app is rejected ------------------------
reset
run FAKE_ASSET_VERSION=0.1.1
check "a wrong-version app does not reach the swap" test "$(applied)" = 0
check "a wrong-version app clears the record" test ! -e "$data/local/state/update-notice"
check "a wrong-version app explains the refusal" grep -qi 'wrong version' "$tmp/out"

# --- the download fails -----------------------------------------------------------
reset
run FAKE_DOWNLOAD_RC=7
check "a failed download does not mount" test "$(count hdiutil)" = 0
check "a failed download does not reach the swap" test "$(applied)" = 0
check "a failed download clears the record" test ! -e "$data/local/state/update-notice"
check "a failed download leaves no file behind" \
  test -z "$(ls "$tmp"/mash-update* 2>/dev/null)"

# --- the image will not mount -------------------------------------------------------
reset
run FAKE_MOUNT_RC=1
check "a failed mount does not reach the swap" test "$(applied)" = 0
check "a failed mount clears the record" test ! -e "$data/local/state/update-notice"

# --- the confirmation ------------------------------------------------------------
reset n
run
check "declining does not reach the swap" test "$(applied)" = 0
check "declining keeps the announcement record" grep -qx 0.2.0 "$data/local/state/update-notice"
check "declining does not set a retry" test ! -e "$data/local/state/update-retry"
check "declining detaches the image" grep -q 'hdiutil detach' "$calls"

reset
mkdir -p "$data/run/default" "$data/run/2"
echo $$ >"$data/run/default/window.pid"
echo $$ >"$data/run/2/window.pid"
run
check "the confirmation names how many windows will close" grep -q '2 Mash window' "$tmp/out"
rm -rf "$data/run"

# --- the staged copy is what gets handed over, not the mount ----------------------
reset
run
staged="$(sed -n 's/^apply .*--app \([^ ]*\).*/\1/p' "$calls" | head -1)"
check "the swap is handed a staged copy, not the mounted image" \
  bash -c '[ -n "'"$staged"'" ] && case "'"$staged"'" in "'"$tmp"'/mnt"*) exit 1 ;; esac'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
