#!/usr/bin/env bash
# mash-tool-refresh re-asserts pinned versions on launch.
#
# Setup runs once, so without this a raised pin reaches only new installations.
# The behaviour that matters is narrow and easy to get wrong:
#
#   * a pin that moved is restored
#   * a pin that matches costs nothing and changes nothing
#   * only components Mash installed here are touched
#   * a launch is never blocked, never prompted, never failed
#
# A fake manifest and installer stand in for the network, so this runs
# anywhere. The real installer is covered by test-mash-tool-install.sh.
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/mash-tool-refresh"
[ -x "$helper" ] || {
  echo "mash-tool-refresh is missing or not executable" >&2
  exit 1
}
# The launcher starts it on every open; a helper that is not shipped never runs.
grep -qx '  mash-tool-refresh' "$(dirname "$helper")/../build.sh" || {
  echo "macOS build does not ship mash-tool-refresh" >&2
  exit 1
}
grep -q 'mash-tool-refresh' "$(dirname "$helper")/../herdr-pane" || {
  echo "the launcher never starts mash-tool-refresh" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
res="$tmp/res"
data="$tmp/home/.mash"
mkdir -p "$res/bin" "$data/setup"
cp "$helper" "$res/bin/mash-tool-refresh"
chmod +x "$res/bin/mash-tool-refresh"

# A stand-in installer: records every component it was asked to refresh, and
# fails for one name so the failure path is exercised too.
cat >"$res/bin/mash-tool-install" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$MASH_DATA_DIR/asked"
case "$1" in
unreachable) exit 1 ;;
system-provided) exit 3 ;;
*) exit 0 ;;
esac
SH
chmod +x "$res/bin/mash-tool-install"

run() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin MASH_DATA_DIR="$data" \
    "$res/bin/mash-tool-refresh" "$data"
}

# --- nothing installed: nothing to do ---------------------------------------
run || {
  echo "refresh failed on an empty data folder" >&2
  exit 1
}
[ ! -f "$data/asked" ] || {
  echo "refresh called the installer with nothing installed" >&2
  exit 1
}

# --- only what Mash installed here ------------------------------------------
# A pinned binary, an npm package and a python tool, each with its marker.
mkdir -p "$data/local/tools/marksman/2026-02-08"
printf '2026-02-08\n' >"$data/local/tools/marksman/2026-02-08/.mash-installed"
mkdir -p "$data/local/npm"
printf '3.9.9\n' >"$data/local/npm/.mash-version-prettier"
mkdir -p "$data/local/venv/python-lsp-server"
printf '1.15.0\n' >"$data/local/venv/python-lsp-server/.mash-version"
# A failed install leaves a versioned directory with no marker: not a candidate.
mkdir -p "$data/local/tools/texlab/5.26.0"
# A tool the platform provides was never installed by Mash: no marker, no call.
mkdir -p "$data/local/tools"

rm -f "$data/asked"
run || {
  echo "refresh failed with components installed" >&2
  exit 1
}
sort -u "$data/asked" >"$tmp/got"
printf 'marksman\nprettier\npython-lsp-server\n' >"$tmp/want"
if ! cmp -s "$tmp/got" "$tmp/want"; then
  echo "refresh asked for the wrong set of components:" >&2
  diff "$tmp/want" "$tmp/got" >&2 || true
  exit 1
fi

# --- an incomplete install is not refreshed ---------------------------------
grep -qx texlab "$data/asked" && {
  echo "refresh touched a component with no completed install" >&2
  exit 1
}

# --- a failure keeps the installed version and never fails the launch -------
mkdir -p "$data/local/tools/unreachable/1.0"
printf '1.0\n' >"$data/local/tools/unreachable/1.0/.mash-installed"
rm -f "$data/asked"
run || {
  echo "a component that could not be refreshed failed the whole run" >&2
  exit 1
}
grep -q 'unreachable could not be refreshed' "$data/setup/tool-refresh.log" || {
  echo "the failure was not reported in the log" >&2
  exit 1
}

# --- exit 3 is "the platform provides it", not a failure --------------------
mkdir -p "$data/local/tools/system-provided/1.0"
printf '1.0\n' >"$data/local/tools/system-provided/1.0/.mash-installed"
rm -f "$data/asked"
run || {
  echo "a system-provided component failed the run" >&2
  exit 1
}
grep -q 'system-provided could not be refreshed' "$data/setup/tool-refresh.log" && {
  echo "exit 3 was treated as a failure" >&2
  exit 1
}

# --- it defers while setup is installing ------------------------------------
mkdir -p "$data/setup/tool-install.lock"
rm -f "$data/asked"
run || {
  echo "refresh failed while a setup install was running" >&2
  exit 1
}
[ ! -f "$data/asked" ] || {
  echo "refresh ran while setup was installing; both drive the same installer" >&2
  exit 1
}
rmdir "$data/setup/tool-install.lock"

# --- a stale lock of its own is recovered, a live one is respected ----------
mkdir -p "$data/setup/tool-refresh.lock"
rm -f "$data/asked"
run || {
  echo "refresh failed on a held lock" >&2
  exit 1
}
[ ! -f "$data/asked" ] || {
  echo "refresh ignored its own lock" >&2
  exit 1
}
rmdir "$data/setup/tool-refresh.lock"

# Hindsight has a dedicated environment, not one of the generic marker paths.
# Its version check is useless on launch unless this helper invokes it too.
cat >"$res/bin/mash-hindsight-install" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >"$MASH_DATA_DIR/hindsight-refreshed"
SH
chmod +x "$res/bin/mash-hindsight-install"
run
[ ! -e "$data/hindsight-refreshed" ] || {
  echo "refresh installed Hindsight for someone who had not installed it" >&2
  exit 1
}
mkdir -p "$data/local/share/mash/hindsight/bin"
printf '#!/bin/sh\nexit 0\n' >"$data/local/share/mash/hindsight/bin/hindsight-embed"
chmod +x "$data/local/share/mash/hindsight/bin/hindsight-embed"
run
[ -f "$data/hindsight-refreshed" ] || {
  echo "existing Hindsight was skipped because its environment is outside generic markers" >&2
  exit 1
}
[ "$(cat "$data/hindsight-refreshed")" = "$data" ] || {
  echo "Hindsight refresh received the wrong data directory" >&2
  exit 1
}

echo "mash-tool-refresh: ok"
