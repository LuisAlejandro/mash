#!/bin/bash
# The update notice: one popup and one desktop notification per newer version.
# Linux decides from the local APT cache; macOS asks the GitHub releases API at
# most once a day. Both share the claim-before-showing rule.
#
# Every tool the helper calls is a stub on a PATH that holds nothing else, so
# the real dpkg, apt-cache, curl, notify-send or herdr of the machine running
# the suite can never answer instead.
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
for t in bash cat mkdir rm mv sed head grep seq sort tail date dirname chmod; do
  ln -s "$(command -v "$t")" "$tools/$t"
done
# The system interpreter by absolute path: a `command -v python3` inside Mash
# finds the bundle's wrapper, which resolves its real interpreter relative to
# its own location and cannot run from this harness.
ln -s "$([ -x /usr/bin/python3 ] && echo /usr/bin/python3 || command -v python3)" "$tools/python3"

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
# One release payload, shaped like the GitHub API's.
stub curl 'echo "curl $*" >>"$CALLS"
[ -n "${FAKE_CURL_RC:-}" ] && exit "$FAKE_CURL_RC" 2>/dev/null
printf "{\"tag_name\": \"%s\", \"name\": \"Release\"}\n" "${FAKE_RELEASE-0.2.0}"'
stub notify-send 'echo "notify $*" >>"$CALLS"'
stub clear ':'
stub gdbus 'echo "gdbus $*" >>"$CALLS"; exit "${FAKE_GDBUS_RC:-0}"'
stub codesign 'echo "TeamIdentifier=${FAKE_TEAM:-4SCJW6LZ6T}" >&2'
stub herdr 'case "$1 $2" in
"status server") echo "status: running" ;;
"plugin pane") echo "popup $*" >>"$CALLS" ;;
esac'
cp "$fake/herdr" "$res/bin/herdr"

run() { # run [VAR=value...] -- one launch's worth of the helper
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" "$@" \
    bash "$helper" "$res" "$data" 2>"$tmp/stderr"
}
run_manual() { # run_manual [VAR=value...] -- one user-requested check
  mkdir -p "$data/local/state"
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" "$@" \
    bash "$helper" --manual "$res" "$data" 2>"$tmp/stderr"
}
count() { grep -c "^$1 " "$calls" 2>/dev/null || true; }
show_status() { # show_status STATUS SYSTEM -- render the manual result pane
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" \
    MASH_UPDATE_STATUS="$1" MASH_UPDATE_SYSTEM="$2" \
    MASH_UPDATE_INSTALLED=0.2.0 HERDR_PANE_ID=manual \
    bash "$root/packaging/plugins/mash-update-notice/notice.sh" \
    >"$tmp/status-out" 2>"$tmp/status-stderr" || true
}
fresh() {
  data="$tmp/data-$1"
  mkdir -p "$data"
  : >"$calls"
}

# --- a newer candidate: record it, notify once, open the popup once -----------
fresh newer
run FAKE_INSTALLED=0.1.1 FAKE_CANDIDATE=0.2.0
check "the newer version is recorded" grep -qx 0.2.0 "$data/local/state/update-notice"
check "the announcement is logged" \
  grep -q 'announcing 0\.2\.0 via notice (running 0\.1\.1)' "$data/local/state/update-notice.log"
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

# --- macOS ---------------------------------------------------------------------
# The bundle the helper decides it is running inside: it derives that from its
# own path, so the helper is copied into a stand-in Mash.app for these.
appdir="$tmp/Applications"
mkdir -p "$appdir/Mash.app/Contents/Resources/bin"
app="$appdir/Mash.app"
cp "$helper" "$app/Contents/Resources/bin/mash-update-notice"
cp "$fake/herdr" "$app/Contents/Resources/bin/herdr"
# macOS delivers notifications through the bundle's own wrapper, not notify-send.
printf '#!/bin/bash\necho "notify $*" >>"$CALLS"\n' \
  >"$app/Contents/Resources/bin/mash-notify"
chmod +x "$app/Contents/Resources/bin/mash-notify"
appres="$app/Contents/Resources"
mac() { # mac [VAR=value...] -- one macOS launch, run from inside the bundle
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_UNAME=Darwin "$@" \
    bash "$appres/bin/mash-update-notice" "$appres" "$data" 2>"$tmp/stderr"
}
mac_manual() { # mac_manual [VAR=value...] -- one user-requested macOS check
  mkdir -p "$data/local/state"
  env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_UNAME=Darwin "$@" \
    bash "$appres/bin/mash-update-notice" --manual "$appres" "$data" 2>"$tmp/stderr"
}
setversion() { printf '%s\n' "$1" >"$appres/VERSION"; }

# --- a newer release: check, record, notify, open the interactive pane ---------
fresh mac-newer
setversion 0.1.1
mac FAKE_RELEASE=0.2.0
check "the macOS release is recorded" grep -qx 0.2.0 "$data/local/state/update-notice"
check "the check time is recorded" test -s "$data/local/state/update-checked"
check "the releases API is asked once" test "$(count curl)" = 1
check "the request names the latest release endpoint" \
  grep -q 'curl .*api\.github\.com/repos/LuisAlejandro/mash/releases/latest' "$calls"
check "macOS notifies once" test "$(count notify)" = 1
check "macOS opens the interactive update pane" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint update' "$calls"
check "the interactive popup has room for download and confirmation" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint update --placement popup --width 64 --height 16' "$calls"
check "the pane receives both versions" \
  grep -q 'MASH_UPDATE_INSTALLED=0.1.1 .*MASH_UPDATE_CANDIDATE=0.2.0' "$calls"

# --- the rate limit ------------------------------------------------------------
: >"$calls"
mac FAKE_RELEASE=0.3.0
check "a second launch within 24h asks nothing" test "$(count curl)" = 0
check "a rate-limited launch shows nothing" test ! -s "$calls"

: >"$calls"
printf '%s\n' "$(($(date +%s) - 90000))" >"$data/local/state/update-checked"
mac FAKE_RELEASE=0.3.0
check "a launch after 24h asks again" test "$(count curl)" = 1
check "a newer release after the window is announced" test "$(count popup)" = 1

# --- a user-requested check bypasses the daily cooldown ------------------------
fresh mac-manual-repeat
setversion 0.1.1
mkdir -p "$data/local/state"
echo 0.2.0 >"$data/local/state/update-notice"
echo "$(date +%s)" >"$data/local/state/update-checked"
mac_manual FAKE_RELEASE=0.2.0
check "manual check asks despite the 24h cooldown" test "$(count curl)" = 1
check "manual check reopens an already-announced update" test "$(count popup)" = 1
: >"$calls"
mac FAKE_RELEASE=0.2.0
check "manual check leaves automatic checks rate-limited for 24h" test "$(count curl)" = 0
check "the reason a launch showed nothing is logged" \
  grep -q 'macos: next check in [0-9]*s' "$data/local/state/update-notice.log"

fresh mac-manual-current
setversion 0.2.0
mac_manual FAKE_RELEASE=0.2.0
check "manual check reports that Mash is up to date" \
  grep -q 'MASH_UPDATE_STATUS=up-to-date' "$calls"
check "manual up-to-date result opens the status pane" \
  grep -q 'plugin pane open --plugin mash-update-notice --entrypoint notice' "$calls"

fresh mac-manual-offline
setversion 0.1.1
mac_manual FAKE_RELEASE=0.2.0 FAKE_CURL_RC=7
check "manual offline check reports that it could not check" \
  grep -q 'MASH_UPDATE_STATUS=check-unavailable' "$calls"
check "a failed release check is logged" \
  grep -q 'macos: release check failed' "$data/local/state/update-notice.log"
fresh mac-manual-malformed
setversion 0.1.1
mac_manual FAKE_RELEASE=not-a-version
check "manual check rejects an unparseable release tag" \
  grep -q 'MASH_UPDATE_STATUS=check-unavailable' "$calls"

fresh linux-manual-current
run_manual FAKE_INSTALLED=0.2.0 FAKE_CANDIDATE=0.2.0
check "manual Linux check reports that Mash is up to date" \
  grep -q 'MASH_UPDATE_STATUS=up-to-date' "$calls"

fresh linux-manual-cache
run_manual FAKE_INSTALLED=0.2.0 'FAKE_CANDIDATE=(none)'
check "manual Linux check explains missing APT metadata" \
  grep -q 'MASH_UPDATE_STATUS=apt-unavailable' "$calls"

show_status up-to-date Darwin
check "macOS manual status says everything is up to date" \
  grep -q 'Everything is up to date' "$tmp/status-out"
show_status up-to-date Linux
check "Linux manual status qualifies its cached APT result" \
  grep -q 'No newer Mash version found in the current APT metadata' "$tmp/status-out"

# --- an announced version is not re-announced ----------------------------------
fresh mac-already-announced
setversion 0.1.1
mkdir -p "$data/local/state"
echo 0.3.0 >"$data/local/state/update-notice"
printf '%s\n' "$(($(date +%s) - 90000))" >"$data/local/state/update-checked"
mac FAKE_RELEASE=0.3.0
check "an announced release is not shown again" test "$(count popup)" = 0
check "a suppressed re-announcement is logged" \
  grep -q '0\.3\.0 already announced' "$data/local/state/update-notice.log"

# --- equal, older, and unparseable tags ----------------------------------------
fresh mac-equal
setversion 0.2.0
mac FAKE_RELEASE=0.2.0
check "an up-to-date macOS install shows nothing" test ! -s "$calls" -o "$(count popup)" = 0
check "an up-to-date macOS install records nothing" test ! -e "$data/local/state/update-notice"
fresh mac-older
setversion 0.3.0
mac FAKE_RELEASE=0.2.0
check "an older release shows nothing" test "$(count popup)" = 0
fresh mac-junk
setversion 0.1.1
mac FAKE_RELEASE=not-a-version
check "an unparseable tag shows nothing" test "$(count popup)" = 0
fresh mac-empty-tag
setversion 0.1.1
mac FAKE_RELEASE=
check "an empty tag shows nothing" test "$(count popup)" = 0

# --- the network is unreachable -------------------------------------------------
fresh mac-offline
setversion 0.1.1
mac FAKE_RELEASE=0.2.0 FAKE_CURL_RC=7
status=$?
check "an offline check exits 0" test "$status" = 0
check "an offline check shows nothing" test "$(count popup)" = 0
check "an offline check prints nothing" test ! -s "$tmp/stderr"
check "an offline check records no version" test ! -e "$data/local/state/update-notice"

# --- no VERSION to compare against ----------------------------------------------
fresh mac-noversion
rm -f "$appres/VERSION"
mac FAKE_RELEASE=0.2.0
check "an unknown running version shows nothing" test "$(count popup)" = 0
setversion 0.1.1

# --- two windows at once: one request, one announcement -------------------------
fresh mac-race
setversion 0.1.1
mac FAKE_RELEASE=0.2.0 &
mac FAKE_RELEASE=0.2.0 &
wait
check "concurrent macOS launches ask once" test "$(count curl)" = 1
check "concurrent macOS launches open one pane" test "$(count popup)" = 1

# --- the first window on the installed version confirms success -----------------
fresh mac-updated
setversion 0.2.0
mkdir -p "$data/local/state"
echo 0.2.0 >"$data/local/state/update-success"
mac FAKE_RELEASE=0.3.0
check "success opens a confirmation pane" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint updated' "$calls"
check "success notification names the new version" grep -q 'notify .*Mash updated to 0.2.0' "$calls"
check "success marker is consumed once" test ! -f "$data/local/state/update-success"
check "success makes no GitHub request" test "$(count curl)" = 0
: >"$calls"
mac FAKE_RELEASE=0.3.0
check "confirmation does not repeat" test "$(count popup)" = 0

# --- a failed update is re-offered without violating the daily request limit ---
fresh mac-retry
setversion 0.1.1
mkdir -p "$data/local/state"
echo 0.2.0 >"$data/local/state/update-retry"
echo "$(date +%s)" >"$data/local/state/update-checked"
mac FAKE_RELEASE=0.2.0
check "a failed update is offered again" test "$(count popup)" = 1
check "a failed update needs no second GitHub request" test "$(count curl)" = 0
check "a retry is claimed once" grep -qx 0.2.0 "$data/local/state/update-notice"
check "a retry marker is consumed" test ! -f "$data/local/state/update-retry"

# --- an interrupted swap is reconciled on next launch --------------------------
fresh mac-interrupted-old
setversion 0.1.1
mkdir -p "$data/local/state"
echo 0.2.0 >"$data/local/state/update-pending"
echo 0.2.0 >"$data/local/state/update-notice"
echo "$(date +%s)" >"$data/local/state/update-checked"
mac FAKE_RELEASE=0.3.0
check "interrupted old app is offered the same version again" test "$(count popup)" = 1
check "interrupted swap reports failure" grep -q 'notify .*Mash update failed' "$calls"
check "interrupted swap makes no second request" test "$(count curl)" = 0
check "interrupted swap consumes pending state" test ! -f "$data/local/state/update-pending"

fresh mac-interrupted-new
setversion 0.2.0
mkdir -p "$data/local/state"
echo 0.2.0 >"$data/local/state/update-pending"
mac FAKE_RELEASE=0.3.0
check "interrupted new app confirms the installed version" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint updated' "$calls"
check "interrupted new app consumes pending state" test ! -f "$data/local/state/update-pending"

# --- the updatable-location verdict reaches the pane ----------------------------
fresh mac-writable
setversion 0.1.1
mac FAKE_RELEASE=0.2.0
check "a writable bundle offers the update" grep -q 'MASH_UPDATE_CAN_APPLY=1' "$calls"
check "the pane is told which bundle to replace" \
  grep -q "MASH_UPDATE_APP=$app" "$calls"

fresh mac-unsigned
setversion 0.1.1
mac FAKE_RELEASE=0.2.0 FAKE_TEAM='not set'
check "an unsigned developer build gets a manual-only notice" \
  grep -q 'MASH_UPDATE_CAN_APPLY=0' "$calls"

fresh mac-readonly
setversion 0.1.1
chmod a-w "$appdir"
mac FAKE_RELEASE=0.2.0
chmod u+w "$appdir"
check "a read-only parent still announces" test "$(count popup)" = 1
check "a read-only parent offers no update" grep -q 'MASH_UPDATE_CAN_APPLY=0' "$calls"

# A dist tree or any other non-.app location cannot be swapped.
fresh mac-notapp
plain="$tmp/plain/Resources"
mkdir -p "$plain/bin"
cp "$helper" "$plain/bin/mash-update-notice"
cp "$fake/herdr" "$plain/bin/herdr"
printf '0.1.1\n' >"$plain/VERSION"
env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_UNAME=Darwin FAKE_RELEASE=0.2.0 \
  bash "$plain/bin/mash-update-notice" "$plain" "$data" 2>"$tmp/stderr"
check "a non-.app location still announces" test "$(count popup)" = 1
check "a non-.app location offers no update" grep -q 'MASH_UPDATE_CAN_APPLY=0' "$calls"

# --- a build with no release channel (macos-amd64) never updates ---------------
# build.sh drops Resources/updates-disabled for any target the official releases
# do not cover. The automatic check and the manual one must both honour it.
nochan="$tmp/nochannel/Mash.app/Contents/Resources"
mkdir -p "$nochan/bin"
cp "$helper" "$nochan/bin/mash-update-notice"
cp "$fake/herdr" "$nochan/bin/herdr"
printf '#!/bin/bash\necho "notify $*" >>"$CALLS"\n' >"$nochan/bin/mash-notify"
chmod +x "$nochan/bin/mash-notify"
printf '0.1.1\n' >"$nochan/VERSION"
printf 'No release channel for macos-amd64; updates are disabled in this build.\n' >"$nochan/updates-disabled"

fresh mac-disabled
env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_UNAME=Darwin FAKE_RELEASE=0.9.0 \
  bash "$nochan/bin/mash-update-notice" "$nochan" "$data" 2>"$tmp/stderr"
check "a build without a release channel never asks GitHub" test "$(count curl)" = 0
check "an automatic launch announces nothing" test ! -s "$calls"
check "no release is recorded" test ! -e "$data/local/state/update-notice"
check "the check time is not recorded" test ! -e "$data/local/state/update-checked"
check "the reason is logged" grep -q 'updates are disabled' "$data/local/state/update-notice.log"

: >"$calls"
env -i HOME="$tmp" PATH="$fake:$tools" CALLS="$calls" FAKE_UNAME=Darwin FAKE_RELEASE=0.9.0 \
  bash "$nochan/bin/mash-update-notice" --manual "$nochan" "$data" 2>"$tmp/stderr"
check "a manual check still never asks GitHub" test "$(count curl)" = 0
check "a manual check opens a notice pane that says why" \
  grep -q 'popup plugin pane open --plugin mash-update-notice --entrypoint notice .*MASH_UPDATE_STATUS=updates-disabled' "$calls"
check "a manual check offers no update" grep -q 'MASH_UPDATE_CAN_APPLY=0' "$calls"
show_status updates-disabled Darwin
check "the pane tells the user updates are disabled" grep -q 'Updates are disabled in this build' "$tmp/status-out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
