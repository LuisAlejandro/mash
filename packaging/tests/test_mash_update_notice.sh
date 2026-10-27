#!/bin/bash
# The Linux update notice: one popup and one desktop notification per newer
# letsmash version, decided from the local APT cache only.
#
# Every tool the helper calls is a stub on a PATH that holds nothing else, so
# the real dpkg, apt-cache, notify-send or herdr of the machine running the
# suite can never answer instead.
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

helper="$root/packaging/helpers/mash-update-notice"
res="$tmp/res"
mkdir -p "$res/bin"

# Only the basics the helper needs, linked from the host.
tools="$tmp/tools"
mkdir -p "$tools"
for t in bash cat mkdir rm mv sed head grep seq sort tail; do
  ln -s "$(command -v "$t")" "$tools/$t"
done

fake="$tmp/fake"
mkdir -p "$fake"
calls="$tmp/calls"
stub() { # stub NAME BODY -- a fake tool on the isolated PATH
  printf '#!/bin/bash\n%s\n' "$2" >"$fake/$1"
  chmod +x "$fake/$1"
}
stub uname 'echo "${FAKE_UNAME:-Linux}"'
stub sleep ':'
stub dpkg-query '[ -n "${FAKE_INSTALLED:-}" ] || exit 1; printf %s "$FAKE_INSTALLED"'
stub apt-cache 'printf "letsmash:\n  Installed: %s\n  Candidate: %s\n" "${FAKE_INSTALLED:-(none)}" "${FAKE_CANDIDATE:-}"'
# Debian ordering is approximated by sort -V, which agrees for plain x.y.z.
stub dpkg '[ "$1" = --compare-versions ] && [ "$3" = gt ] || exit 2
[ "$2" != "$4" ] && [ "$(printf "%s\n%s\n" "$2" "$4" | sort -V | tail -1)" = "$2" ]'
stub notify-send 'echo "notify $*" >>"$CALLS"'
stub gdbus 'echo "gdbus $*" >>"$CALLS"; exit "${FAKE_GDBUS_RC:-0}"'
stub herdr 'case "$1 $2" in
"status server") echo "status: running" ;;
"plugin pane") echo "popup $*" >>"$CALLS" ;;
esac'
cp "$fake/herdr" "$res/bin/herdr"

run() { # run [VAR=value...] -- one launch's worth of the helper
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" "$@" \
    bash "$helper" "$res" "$data" 2>"$tmp/stderr"
}
count() { grep -c "^$1 " "$calls" 2>/dev/null || true; }
fresh() {
  data="$tmp/data-$1"
  mkdir -p "$data"
  : >"$calls"
}

# --- a newer candidate: record it, notify once, open the popup once -----------
fresh newer
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0
check "the newer version is recorded" grep -qx 0.2.0 "$data/local/state/update-notice"
check "one desktop notification" test "$(count notify)" = 1
check "the notification names both versions and the command" \
  grep -q 'notify .*0\.2\.0.*0\.1\.1.*sudo apt install --only-upgrade letsmash' "$calls"
check "one popup" test "$(count popup)" = 1
check "the popup opens the notice pane, centered, at 56x9" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint notice --placement popup --width 56 --height 9' "$calls"
check "the popup receives both versions" \
  grep -q 'MASH_UPDATE_INSTALLED=0.1.1 .*MASH_UPDATE_CANDIDATE=0.2.0' "$calls"
check "no notification daemon fallback when notify-send works" test "$(count gdbus)" = 0

# --- the same version again: nothing --------------------------------------------
: >"$calls"
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0
check "an announced version is not shown again" test ! -s "$calls"

# --- a later release: announced once ------------------------------------------
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.3.0
check "a later release replaces the record" grep -qx 0.3.0 "$data/local/state/update-notice"
check "a later release notifies once" test "$(count notify)" = 1
check "a later release opens one popup" test "$(count popup)" = 1

# --- equal or older candidates --------------------------------------------------
fresh equal
run FAKE_INSTALLED=0.2.0 FAKE_CANDIDATE=0.2.0
check "an up-to-date install shows nothing" test ! -s "$calls"
check "an up-to-date install records nothing" test ! -e "$data/local/state/update-notice"
fresh older
run FAKE_INSTALLED=0.3.0 FAKE_CANDIDATE=0.2.0
check "an older candidate shows nothing" test ! -s "$calls"

# --- no candidate (source removed) and no package (staged build) --------------
fresh none
run FAKE_INSTALLED=0.1.1 'FAKE_CANDIDATE=(none)'
check "a removed source shows nothing" test ! -s "$calls"
fresh empty
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=
check "an empty candidate shows nothing" test ! -s "$calls"
fresh staged
run FAKE_CANDIDATE=0.2.0
check "no installed package shows nothing" test ! -s "$calls"
check "no installed package prints nothing" test ! -s "$tmp/stderr"

# --- macOS never runs the check -------------------------------------------------
fresh darwin
run FAKE_UNAME=Darwin FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0
check "macOS shows nothing" test ! -s "$calls"
check "macOS records nothing" test ! -e "$data/local/state/update-notice"

# --- no notify-send, failing gdbus: the popup still opens -----------------------
mv "$fake/notify-send" "$tmp/notify-send.off"
fresh nodaemon
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0 FAKE_GDBUS_RC=1
status=$?
check "a failed notification still exits 0" test "$status" = 0
check "gdbus is tried when notify-send is absent" test "$(count gdbus)" = 1
check "the popup still opens" test "$(count popup)" = 1
check "the version is still recorded" grep -qx 0.2.0 "$data/local/state/update-notice"
mv "$tmp/notify-send.off" "$fake/notify-send"

# --- two windows at once: exactly one announces ---------------------------------
fresh race
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0 &
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0 &
wait
check "concurrent launches open one popup" test "$(count popup)" = 1
check "concurrent launches notify once" test "$(count notify)" = 1

# --- a lock left by a dead launch is recovered ----------------------------------
fresh stale
mkdir -p "$data/local/state/update-notice.lock"
echo 999999 >"$data/local/state/update-notice.lock/pid"
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0
check "a stale lock does not block the notice" test "$(count popup)" = 1
check "the lock is released afterwards" test ! -e "$data/local/state/update-notice.lock"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
