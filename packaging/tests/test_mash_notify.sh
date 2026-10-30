#!/bin/bash
# The notification click has to survive leaving the pane.
#
# herdr's notifier plugin builds `-execute '<herdr> agent focus <pane>'`, and
# macOS runs that string from Notification Center with Notification Center's
# environment: no HERDR_SOCKET_PATH, so the CLI looks for
# ~/.config/herdr/herdr.sock, reports server_not_running, and clicking the
# notification does nothing. bin/mash-notify rewrites the click so the socket
# paths -- and the window raise -- are baked in while the pane's environment is
# still available.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
check() { # check MSG CMD... -- record a pass when CMD succeeds
  local msg="$1"
  shift
  if "$@"; then ok "$msg"; else nok "$msg"; fi
}

# A stand-in bundle: the wrapper at bin/, a notifier that records its argv.
res="$tmp/res"
mkdir -p "$res/bin" "$res/plugins/dot.terminal-notifier/assets/HerdrNotify.app/Contents/MacOS"
cp "$root/packaging/helpers/mash-notify" "$res/bin/mash-notify"
chmod +x "$res/bin/mash-notify"
recorder="$res/plugins/dot.terminal-notifier/assets/HerdrNotify.app/Contents/MacOS/terminal-notifier"
cat >"$recorder" <<'FAKE'
#!/bin/bash
# One argument per line, so the -execute payload is the exact 2nd line.
printf '%s\n' "$@" >"$NOTIFY_RECORD"
FAKE
chmod +x "$recorder"

# The click payload is executed by macOS. Run it the same way here, with a fake
# `herdr` and a fake `open` on PATH, and record what each receives.
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/herdr" <<'FAKE'
#!/bin/bash
printf 'herdr argc=%s socket=%s args=%s\n' "$#" "${HERDR_SOCKET_PATH:-<unset>}" "$*" >"$CLICK_RECORD"
FAKE
cat >"$fakebin/open" <<'FAKE'
#!/bin/bash
printf 'open %s\n' "$*" >>"$CLICK_RECORD"
FAKE
chmod +x "$fakebin/herdr" "$fakebin/open"

export NOTIFY_RECORD="$tmp/notify.args" CLICK_RECORD="$tmp/click.record"

run_wrapper() { # run_wrapper ENVSPEC... -- call the wrapper with a click payload
  # The test runner's own pane exports the HERDR_* variables, so they have to be
  # cleared for the "no socket in the environment" case to mean anything.
  env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_CONFIG_PATH \
    "$@" "MASH_NOTIFY_REAL=$recorder" NOTIFY_RECORD="$NOTIFY_RECORD" \
    CLICK_RECORD="$CLICK_RECORD" \
    "$res/bin/mash-notify" -title t -message m \
    -execute 'herdr agent focus w5:p1'
}

# --- the click carries the socket the pane had -------------------------------
: >"$NOTIFY_RECORD"
run_wrapper HERDR_SOCKET_PATH="$HOME/.mash/run/herdr.sock" \
  HERDR_CLIENT_SOCKET_PATH="$HOME/.mash/run/herdr-client.sock"
execute="$(grep -v '^-title$\|^-message$\|^t$\|^m$' "$NOTIFY_RECORD" | tail -1)"

check "the click gets the server socket from notify time" \
  grep -q "HERDR_SOCKET_PATH=$HOME/.mash/run/herdr.sock" <<<"$execute"
check "the click gets the client socket too" \
  grep -q "HERDR_CLIENT_SOCKET_PATH=$HOME/.mash/run/herdr-client.sock" <<<"$execute"
check "the click still runs the configured focus command" \
  grep -q 'herdr agent focus w5:p1' <<<"$execute"
check "the window is raised after focusing" \
  grep -q 'open -b app.mash' <<<"$execute"

# --- run the payload the way Notification Center would -----------------------
: >"$CLICK_RECORD"
env -i HOME="$HOME" PATH="$fakebin:/usr/bin:/bin" CLICK_RECORD="$CLICK_RECORD" \
  bash -c "$execute"
check "the baked socket reaches herdr" \
  grep -q "socket=$HOME/.mash/run/herdr.sock" "$CLICK_RECORD"
check "the pane stays exactly one argument" \
  grep -q 'herdr argc=3 .*agent focus w5:p1' "$CLICK_RECORD"
check "the terminal is activated" \
  grep -q 'open -b app.mash' "$CLICK_RECORD"

# --- no sockets in the environment: still focus, still raise ------------------
: >"$NOTIFY_RECORD"
run_wrapper
execute="$(grep -v '^-title$\|^-message$\|^t$\|^m$' "$NOTIFY_RECORD" | tail -1)"
check "no socket env does not break the payload" \
  grep -q '^herdr agent focus w5:p1; open -b app.mash' <<<"$execute"

# --- a pane id with a space can not become two arguments ---------------------
: >"$NOTIFY_RECORD"
NOTIFY_RECORD="$NOTIFY_RECORD" CLICK_RECORD="$CLICK_RECORD" \
  MASH_NOTIFY_REAL="$recorder" "$res/bin/mash-notify" -execute 'herdr agent focus odd\ pane'
execute="$(grep -v '^-title$\|^-message$\|^t$\|^m$' "$NOTIFY_RECORD" | tail -1)"
: >"$CLICK_RECORD"
env -i HOME="$HOME" PATH="$fakebin:/usr/bin:/bin" CLICK_RECORD="$CLICK_RECORD" \
  bash -c "$execute"
check "an escaped pane id stays one argument" \
  grep -q 'herdr argc=3 .*agent focus odd pane' "$CLICK_RECORD"

# --- a missing notifier is silent, never fatal -------------------------------
mkdir -p "$tmp/empty"
check "a tree without the notifier exits quietly" \
  env MASH_NOTIFY_REAL="$tmp/empty/nope" "$res/bin/mash-notify" -title t -message m

# --- the launcher configures this on macOS only ------------------------------
# Linux has no terminal-notifier plugin at all (carry.sh stages it for Darwin
# only); it delivers notifications as OSC9/OSC99 through the terminal, so a
# NOTIFIER line there would point at nothing.
data_dir="$tmp/data"
mkdir -p "$tmp/linux-res/bin" "$data_dir"
cp "$root/packaging/helpers/mash-notify" "$tmp/linux-res/bin/mash-notify"
chmod +x "$tmp/linux-res/bin/mash-notify"
cfg_rel=config/herdr/plugins/config/dot.terminal-notifier/config.env

( set -e; source "$root/packaging/launch-common.sh"
  MASH_UNAME=Linux mash_write_notifier_config "$tmp/linux-res" "$data_dir" )
check "a Linux launch writes no NOTIFIER config" test ! -e "$data_dir/$cfg_rel"

( set -e; source "$root/packaging/launch-common.sh"
  MASH_UNAME=Darwin mash_write_notifier_config "$tmp/linux-res" "$data_dir" )
check "a macOS launch points NOTIFIER at the wrapper" \
  grep -qx "NOTIFIER=$tmp/linux-res/bin/mash-notify" "$data_dir/$cfg_rel"

# A fresh sender identity avoids macOS reusing the former herdr name and icon.
check "notifier uses Mash's new bundle identity" \
  grep -Fq 'Set :CFBundleIdentifier app.mash.notifications' "$root/packaging/carry.sh"
check "uninstall clears the notifier identity" \
  grep -Fq 'app.mash.notifications;' "$root/packaging/uninstall"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
