#!/usr/bin/env bash
# Exercise the real launchd handoff with a private Herdr and unique job label.
# Every cleanup target is this test's own; no production job/app/home is used.
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || ! command -v herdr >/dev/null 2>&1; then
  echo 'SKIP: needs macOS and herdr on PATH'; exit 77
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
root="$(mktemp -d /tmp/mash-handoff.XXXXXX)"
label="app.mash.update.test.$(uuidgen)"
uid="$(id -u)"
job_started=0
herdr_bin="$(command -v herdr)"
cleanup() {
  HERDR_SOCKET_PATH="$root/h.sock" "$herdr_bin" server stop >/dev/null 2>&1 || true
  if [ "$job_started" = 1 ]; then launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true; fi
  rm -rf "$root"
}
trap cleanup EXIT
unset HERDR_SESSION HERDR_PANE_ID HERDR_ENV HERDR_BIN_PATH
export HERDR_SOCKET_PATH="$root/h.sock" HERDR_CLIENT_SOCKET_PATH="$root/c.sock"
export HERDR_CONFIG_PATH="$root/config.toml" XDG_CONFIG_HOME="$root/cfg"
mkdir -p "$root/cfg" "$root/work" "$root/bin" "$root/data/local/state" "$root/Mash.app/Contents" "$root/mash-update-ABCDEF"
printf 'onboarding = false\n\n[terminal]\nshell_mode = "non_login"\ndefault_shell = "/bin/sh"\n' >"$HERDR_CONFIG_PATH"
cp "$repo/packaging/helpers/mash-update-common" "$root/bin/"
xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
  "$repo/packaging/helpers/mash-update-processes.c" -o "$root/bin/mash-update-processes"
# shellcheck source=../helpers/mash-update-common
source "$root/bin/mash-update-common"
mash_update_init "$root/data"
mash_update_begin "$root/Mash.app" 9.9.9 9.9.8 "$root/mash-update-ABCDEF"
mash_update_write job "$label"
cat >"$root/fake-apply" <<EOF
#!/bin/bash
HERDR_SOCKET_PATH="$root/h.sock" "$herdr_bin" server stop >/dev/null 2>&1
sleep 1
printf survived >"$root/finished"
EOF
chmod +x "$root/fake-apply"
cat >"$root/handoff" <<EOF
#!/bin/bash
source "$root/bin/mash-update-common"
mash_update_init "$root/data"
MU_ID="$MU_ID"
mash_update_bootstrap "$root/fake-apply"
EOF
chmod +x "$root/handoff"
(cd "$root/work" && "$herdr_bin" server >/dev/null 2>&1 &)
for _ in $(seq 1 80); do "$herdr_bin" workspace list >/dev/null 2>&1 && break; sleep 0.25; done
"$herdr_bin" workspace create --cwd "$root/work" >/dev/null
pane="$("$herdr_bin" pane list | grep -oE '"pane_id":"[^"]+"' | head -1 | cut -d'"' -f4)"
# Ownership is established before the action that can create the job.
job_started=1
"$herdr_bin" pane run "$pane" "$root/handoff" >/dev/null
for _ in $(seq 1 120); do [ -f "$root/finished" ] && break; sleep 0.25; done
[ -f "$root/finished" ] || { echo 'FAIL: updater died with Herdr' >&2; exit 1; }
if "$herdr_bin" workspace list >/dev/null 2>&1; then
  echo 'FAIL: private Herdr did not stop' >&2; exit 1
fi
echo 'PASS: real detached worker survives private Herdr shutdown'
