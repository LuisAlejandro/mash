#!/bin/bash
# Seed an isolated Mash for a keybinding GUI pass and print how to launch it.
#
#   packaging/tests/keybinding-gui-env.sh <mash|native> [root]
#
# Renders this checkout's defaults through the real seeder into <root>/.mash
# (default /tmp/mash-kb-<mode>), never the user's ~/.mash, and writes:
#
#   <root>/env.sh   source it to reach that instance's Herdr (herdr tab list,
#                   herdr pane read ...) without touching the live one
#   <root>/launch   starts a Mash Terminal window on that instance
#
# The terminal is MASH_TERMINAL (default: the staged Linux build). On a Linux
# Wayland session the window is started under XWayland so cua-driver can
# target it. See packaging/tests/keybinding-modes-gui-pass.md for the pass.
set -euo pipefail
mode="${1:?usage: $0 <mash|native> [root]}"
case "$mode" in mash | native) ;; *) echo "mode is mash or native" >&2; exit 2 ;; esac
repo="$(cd "$(dirname "$0")/../.." && pwd)"
root="$(realpath -m -- "${2:-/tmp/mash-kb-$mode}")"
# This script creates a disposable fixture. Never remove a caller's directory,
# even one named like a fixture: it might contain user data or a running session.
if [ "$(dirname -- "$root")" != /tmp ] || [[ "$(basename -- "$root")" != mash-kb-* ]]; then
  echo "fixture root must be a new /tmp/mash-kb-* directory" >&2
  exit 2
fi
if [ -e "$root" ] || [ -L "$root" ]; then
  echo "fixture root already exists: $root (stop its instance, then remove it yourself)" >&2
  exit 2
fi
stage="$repo/dist/.linux-build/$(python3 "$repo/packaging/assets.py" target)/pkgroot/opt/letsmash"
terminal="${MASH_TERMINAL:-$stage/bin/mash-terminal}"
[ -x "$terminal" ] || { echo "no terminal at $terminal; build first or set MASH_TERMINAL" >&2; exit 1; }

mkdir -m 700 -- "$root"
res="$root/res" d="$root/.mash"
mkdir -p "$res" "$d/setup" "$d/run" "$root/work"
cp -a "$repo/packaging/defaults" "$res/defaults"
: >"$res/defaults/optional-programming.txt"
cp "$repo/VERSION" "$res/VERSION"
# The seeder names herdr-pane under <res>/bin; the launch below runs its own.
mkdir -p "$res/bin"
[ "$mode" = native ] && printf 'mode=native\n' >"$d/setup/keybindings-mode"
"$repo/packaging/helpers/mash-seed-sync" "$res" "$d" >/dev/null
seq -f 'line %g alpha beta gamma' 1 80 >"$root/work/a.txt"
cp "$root/work/a.txt" "$root/work/b.txt"

cat >"$root/env.sh" <<EOF
export PATH="$stage/bin:$stage/python/bin:\$PATH"
export XDG_CONFIG_HOME="$d/config" XDG_STATE_HOME="$d/local/state"
export XDG_DATA_HOME="$d/local/share" XDG_CACHE_HOME="$d/cache"
export HERDR_CONFIG_PATH="$d/config/herdr/config.toml"
export HERDR_SOCKET_PATH="$d/run/herdr.sock" HERDR_CLIENT_SOCKET_PATH="$d/run/herdr-client.sock"
export MASH_FRESH_CONFIG_DIR="$d/config/fresh" MASH_FRESH_DATA_DIR="$d/local/share/fresh"
export PI_CODING_AGENT_DIR="$d/pi/agent"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION TMUX
EOF
cat >"$root/start-herdr" <<EOF
#!/bin/bash
. "$root/env.sh"
cd "$root/work"
exec herdr
EOF
# mash-shell is installed by the launcher, not the seeder; panes use bash here.
sed -i "s#^default_shell = .*#default_shell = \"/bin/bash\"#" "$d/config/herdr/config.toml"
# The seeded Ghostty config runs the bundle's herdr-pane; point it here.
sed -i "s#^command = .*#command = $root/start-herdr#" "$d/config/ghostty/config"
cat >"$root/launch" <<EOF
#!/bin/bash
. "$root/env.sh"
export GDK_BACKEND="\${GDK_BACKEND:-x11}"
# The seeded config makes Mash a single GTK instance, so without this the window
# would hand itself to a Mash already running on this desktop instead of
# opening on the throwaway data folder.
exec "$terminal" --gtk-single-instance=false --title="MashKB $mode" >"$root/terminal.log" 2>&1
EOF
chmod +x "$root/start-herdr" "$root/launch"
echo "$root"
