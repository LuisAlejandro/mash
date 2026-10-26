#!/bin/bash
# First-launch seeding, shared by the macOS app launcher and the Linux
# launcher. Sources under the caller's ROOT; every function takes the resource
# root and the data directory explicitly, so the same code fills ~/.mash from a
# Contents/Resources tree or from /opt/letsmash.
#
# Nothing here writes outside the data directory it is given.

mash_seed_missing() {
  local src="$1"
  local dest="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dest"
  # One process, not one mkdir+cp per file. defaults/pi is 52k files, and the
  # per-file loop made the first open look like a hang. --ignore-existing
  # keeps whatever the user already has, and skips what it must skip without
  # failing the way `cp -n` does.
  rsync -a --ignore-existing "$src/" "$dest/"
}

# Seeding never overwrites, so a shipped patch reaches an install that already
# ran Mash only through a repair. The bundled Herdr integration is authoritative
# for that one file, and the marker line in it is how a stale copy is
# recognised: Herdr rewrites the file on every integration update.
mash_repair_pi_integration() {
  local src="$1" d="$2" bundled installed marker
  bundled="$src/defaults/pi/extensions/herdr-agent-state.ts"
  installed="$d/pi/agent/extensions/herdr-agent-state.ts"
  [ -f "$bundled" ] || return 0
  marker="$(sed -n 's/.*\(MASH_PATCH=restore-resume\).*/\1/p' "$bundled" | head -n 1)"
  [ -n "$marker" ] || return 0
  grep -qF -- "$marker" "$installed" 2>/dev/null && return 0
  mkdir -p "$d/pi/agent/extensions"
  cp "$bundled" "$installed"
}

# The notifier's click runs from Notification Center, which has none of the
# pane's herdr environment: without the socket path the click looks for
# ~/.config/herdr/herdr.sock, finds nothing, and does nothing at all -- and it
# could not raise the window even if it found the server. bin/mash-notify
# rewrites that click at notify time, when the paths are still available. The
# absolute path is written here because only the launcher knows where the bundle
# lives. Any other NOTIFIER line is dropped so the setting cannot go stale after
# moving the app.
mash_write_notifier_config() {
  local res="$1" d="$2" cfg tmp
  cfg="$d/config/herdr/plugins/config/dot.terminal-notifier/config.env"
  # macOS only: the notifier plugin is staged for Darwin alone (carry.sh), and
  # Linux delivers notifications as OSC9/OSC99 through the terminal instead.
  # Writing NOTIFIER there would configure a plugin that does not exist.
  [ "${MASH_UNAME:-$(uname -s)}" = "Darwin" ] || return 0
  [ -x "$res/bin/mash-notify" ] || return 0
  mkdir -p "$(dirname "$cfg")"
  tmp="$cfg.tmp"
  : >"$tmp"
  [ -f "$cfg" ] && grep -v '^NOTIFIER=' "$cfg" >>"$tmp"
  printf 'NOTIFIER=%s\n' "$res/bin/mash-notify" >>"$tmp"
  mv "$tmp" "$cfg"
}

# References and the mash-parallel venv live under ~/.mash/config/mash.
# The venv's Python symlink is retargeted at this bundle. Existing files stay.
mash_seed_programming_skills() {
  local src venv py cfg current script
  src="$res/defaults/mash-config"
  [ -d "$src" ] || return 0
  mash_seed_missing "$src/references" "$d/config/mash/references"
  if [ ! -f "$d/config/mash/hindsight-pin" ] && [ -f "$src/hindsight-pin" ]; then
    cp "$src/hindsight-pin" "$d/config/mash/hindsight-pin"
  fi
  venv="$d/config/mash/venvs/mash-parallel"
  if [ -d "$src/venvs/mash-parallel" ] && [ ! -e "$venv/pyvenv.cfg" ]; then
    mkdir -p "$d/config/mash/venvs"
    cp -a "$src/venvs/mash-parallel" "$venv"
  fi
  py="$res/python/bin/python3"
  if [ -d "$venv/bin" ] && [ -x "$py" ]; then
    current="$(readlink "$venv/bin/python" 2>/dev/null || true)"
    [ "$current" = "$py" ] || ln -sfn "$py" "$venv/bin/python"
    current="$(readlink "$venv/bin/python3" 2>/dev/null || true)"
    [ "$current" = "python" ] || ln -sfn python "$venv/bin/python3"
    if [ -L "$venv/bin/python3.13" ]; then
      current="$(readlink "$venv/bin/python3.13" 2>/dev/null || true)"
      [ "$current" = "python" ] || ln -sfn python "$venv/bin/python3.13"
    fi
    cfg="$venv/pyvenv.cfg"
    if [ -f "$cfg" ]; then
      awk -v homebin="$res/python/bin" -v exe="$py" '
                BEGIN { h = 0; e = 0 }
                /^home[[:space:]]*=/ { print "home = " homebin; h = 1; next }
                /^executable[[:space:]]*=/ { print "executable = " exe; e = 1; next }
                { print }
                END {
                    if (!h) print "home = " homebin
                    if (!e) print "executable = " exe
                }
            ' "$cfg" >"$cfg.tmp"
      if cmp -s "$cfg.tmp" "$cfg"; then
        rm -f "$cfg.tmp"
      else
        mv "$cfg.tmp" "$cfg"
      fi
    fi
    PYTHONNOUSERSITE=1 "$py" - "$venv" <<'PY'
import os, sys
venv = sys.argv[1]
bindir = os.path.join(venv, "bin")
want = b"#!" + os.path.join(bindir, "python").encode() + b"\n"
for name in os.listdir(bindir):
    path = os.path.join(bindir, name)
    if os.path.islink(path) or not os.path.isfile(path):
        continue
    with open(path, "rb") as fh:
        data = fh.read()
    head, sep, tail = data.partition(b"\n")
    if not head.startswith(b"#!") or b"python" not in head:
        continue
    updated = want + tail
    if updated != data:
        with open(path, "wb") as fh:
            fh.write(updated)
PY
  fi
  script="$d/pi/agent/skills/mash-parallel"
  if [ -d "$script" ] && [ -d "$venv" ] && [ ! -e "$script/.venv" ]; then
    ln -s "$venv" "$script/.venv"
  fi
}

# Hindsight keeps its state under the data folder: its warm-start re-exports
# HOME for its process tree alone, so Path.home() resolves here. The config is
# seeded once, and the owner's provider key is added in place — never shipped.
mash_seed_hindsight() {
  local src="$res/defaults/mash-config/hindsight-embed.env"
  [ -f "$src" ] || return 0
  mkdir -p "$d/.hindsight" "$d/.local/bin" "$d/.pg0" "$d/setup"
  [ -f "$d/.hindsight/embed" ] || cp "$src" "$d/.hindsight/embed"
}


# The design stack: payload, dependency stores, the skill symlinks, and the
# penpot-local MCP entry. Env values come from penpot.env, which `mds setup`
# writes. Before that they are empty and the server reports it.
mash_seed_design_stack() {
  local src="$res/defaults/design-stack"
  local cfg="$d/config/mash"
  local stack="$d/local/share/mash/design"
  local py="$res/python/bin/python3"
  local node="$res/node/bin/node"
  local name target

  [ -d "$src" ] || return 0
  mkdir -p "$stack" "$cfg/node_modules" "$cfg/venvs"
  rsync -a --ignore-existing "$src/" "$stack/"
  mash_seed_missing "$res/defaults/mash-config/headless" "$cfg/headless"
  mash_seed_missing "$res/defaults/mash-config/node_modules" "$cfg/node_modules"
  for name in "$res/defaults/mash-config/venvs"/*; do
    [ -d "$name" ] || continue
    target="$cfg/venvs/$(basename "$name")"
    [ -e "$target/pyvenv.cfg" ] && continue
    cp -a "$name" "$target"
  done
  chmod 755 "$stack/bin/mds" 2>/dev/null || true
  chmod 755 "$stack/lib/od_daemon.sh" 2>/dev/null || true
  # On PATH as `mds`. ~/.mash/bin is already in MASH_BIN; the user's own
  # ~/.local/bin is never written to.
  mkdir -p "$d/bin"
  [ -e "$d/bin/mds" ] || ln -s "$stack/bin/mds" "$d/bin/mds"

  # Each installed design skill reaches its dependency store here. The design
  # installer does the same for the IDE copies it writes.
  for name in "$cfg/node_modules"/*; do
    [ -d "$name/node_modules" ] || continue
    target="$d/pi/agent/skills/$(basename "$name")/node_modules"
    [ -d "$(dirname "$target")" ] || continue
    [ -e "$target" ] || ln -s "$name/node_modules" "$target"
  done
  for name in "$cfg/venvs"/*; do
    [ -x "$name/bin/python" ] || continue
    target="$d/pi/agent/skills/$(basename "$name")/.venv"
    [ -d "$(dirname "$target")" ] || continue
    [ -e "$target" ] || ln -s "$name" "$target"
  done

  [ -x "$py" ] && [ -f "$cfg/headless/dist/server.js" ] || return 0
  "$py" - "$d/pi/agent/mcp.json" "$node" "$cfg/headless/dist/server.js" "$stack/penpot.env" <<'PY'
import json, sys
from pathlib import Path

dest, node, server, env_file = sys.argv[1:5]
values = {}
source = Path(env_file)
if source.is_file():
    for line in source.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value

entry = {
    "command": node,
    "args": [server],
    "env": {
        "PENPOT_BASE_URL": "http://localhost:9001",
        "PENPOT_ACCESS_TOKEN": values.get("PENPOT_ACCESS_TOKEN", ""),
        "PENPOT_LOGIN_EMAIL": values.get("PENPOT_LOCAL_EMAIL", ""),
    },
}
path = Path(dest)
if path.is_symlink():
    raise SystemExit("Mash refused a symlink for Pi MCP config")
data = {}
if path.is_file():
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        raise SystemExit(0)
    if isinstance(loaded, dict):
        data = loaded
servers = data.get("mcpServers")
if not isinstance(servers, dict):
    servers = {}
    data["mcpServers"] = servers
if servers.get("penpot-local") != entry:
    servers["penpot-local"] = entry
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}

# Seed the individual config files that are generated rather than copied: the
# Herdr config names the pane shell and data folder, and pet's config names its
# snippet file, so both are substituted at first launch. Every file is seeded
# only when missing, so a user's own edits are never replaced.
#
#   mash_seed_configs <resource-root> <data-dir>
mash_seed_configs() {
  local res="$1" d="$2" suffix=""
  # The three keymaps are platform-specific: Command chords and the macOS
  # notification app make no sense on Linux, and Ctrl chords would shadow the
  # shell on macOS. The .linux variants sit beside the originals.
  [ "$(uname -s)" = "Darwin" ] || suffix=".linux"
  mkdir -p "$d/config/herdr" "$d/config/ghostty" "$d/config/zsh" \
    "$d/config/git" "$d/config/pet"
  if [ ! -f "$d/config/herdr/config.toml" ]; then
    sed -e "s#__MASH_SHELL__#$d/bin/mash-shell#g" \
      -e "s#__MASH_CONFIG__#$d/config#g" \
      "$res/defaults/herdr/config${suffix}.toml" >"$d/config/herdr/config.toml"
  fi
  # The terminal config names herdr-pane by absolute path, so the placeholder is
  # substituted here the same way the Herdr config's shell path is above.
  if [ ! -f "$d/config/ghostty/config" ]; then
    sed -e "s#__MASH_HERDR_PANE__#$res/bin/herdr-pane#g" \
      "$res/defaults/ghostty/config${suffix}" >"$d/config/ghostty/config"
  fi
  # Fresh reads config.json only, so the Linux keymap is seeded under that name.
  # Seeding it before the tree copy below means --ignore-existing leaves it
  # alone instead of replacing it with the macOS keymap.
  if [ -n "$suffix" ] && [ -f "$res/defaults/fresh/config.linux.json" ]; then
    mkdir -p "$d/config/fresh"
    [ -f "$d/config/fresh/config.json" ] ||
      cp "$res/defaults/fresh/config.linux.json" "$d/config/fresh/config.json"
  fi
  [ -f "$d/config/zsh/.zshenv" ] ||
    cp "$res/defaults/zsh/.zshenv" "$d/config/zsh/.zshenv"
  [ -f "$d/config/git/config" ] ||
    cp "$res/defaults/git/config" "$d/config/git/config"
  # git's default global excludes file lives under the XDG directory Mash pins
  # to ~/.mash/config, so it needs no core.excludesFile entry to be read.
  [ -f "$d/config/git/ignore" ] ||
    cp "$res/defaults/git/ignore" "$d/config/git/ignore"
  if [ ! -f "$d/config/pet/snippet.toml" ]; then
    sed "s#__MASH_PET_SNIPPET__#$d/config/pet/snippet.toml#" \
      "$res/defaults/pet/config.toml" >"$d/config/pet/config.toml"
    cp "$res/defaults/pet/snippet.toml" "$d/config/pet/snippet.toml"
  fi
  # The in-product cheat sheet lists chords, so it follows the platform too.
  if [ -n "$suffix" ] &&
    [ -f "$res/defaults/pi/extensions/keybindings-quickref.linux.txt" ]; then
    mkdir -p "$d/pi/agent/extensions"
    [ -f "$d/pi/agent/extensions/keybindings-quickref.txt" ] ||
      cp "$res/defaults/pi/extensions/keybindings-quickref.linux.txt" \
        "$d/pi/agent/extensions/keybindings-quickref.txt"
  fi

  # The pane shell itself is copied out of the read-only tree so a package
  # upgrade does not change the shell underneath a running pane.
  cp "$res/bin/lib.sh" "$d/bin/lib.sh"
  cp "$res/bin/launch-common.sh" "$d/bin/launch-common.sh"
  cp "$res/bin/mash-shell" "$d/bin/mash-shell"
  chmod 755 "$d/bin/lib.sh" "$d/bin/launch-common.sh" "$d/bin/mash-shell"
}

# Seed the whole data directory, in the order the launcher needs it: plain
# config first, then the skill payloads that reference it, then the pieces that
# depend on a runtime being in place.
#
#   mash_seed_all <resource-root> <data-dir> <account-home>
mash_seed_all() {
  local res="$1" d="$2" home="$3"
  mkdir -p \
    "$d/config/herdr" "$d/config/ghostty" "$d/config/git" "$d/config/gh" \
    "$d/config/fresh" "$d/config/zsh" "$d/config/pet" "$d/config/atuin" \
    "$d/config/lazygit" "$d/config/lazydocker" "$d/config/mash" \
    "$d/local/state" "$d/local/share/fresh" "$d/local/share/zoxide" \
    "$d/cache" "$d/pi/agent" "$d/run" "$d/bin"

  mash_seed_configs "$res" "$d"
  mash_seed_missing "$res/defaults/ghostty/themes" "$d/config/ghostty/themes"
  mash_seed_missing "$res/defaults/fresh" "$d/config/fresh"
  mash_seed_missing "$res/defaults/pi" "$d/pi/agent"
  mash_repair_pi_integration "$res" "$d"
  mash_seed_missing "$res/defaults/plugins" "$d/config/herdr/plugins/config"
  mash_write_notifier_config "$res" "$d"
  mash_seed_missing "$res/defaults/atuin" "$d/config/atuin"
  mash_seed_missing "$res/defaults/lazydocker" "$d/config/lazydocker"
  mash_seed_programming_skills
  mash_seed_design_stack
  mash_seed_hindsight
}

mash_link_plugins() {
  local dir listed py data_dir plan
  [ -d "$res/plugins" ] || return 0
  listed="$XDG_CONFIG_HOME/herdr/plugins.json"
  py="$res/python/bin/python3"
  [ -x "$py" ] || py="/usr/bin/python3"
  data_dir="$XDG_DATA_HOME/herdr/plugins"
  # Which carried plugins need linking. Herdr keeps a copy of each manifest in
  # the registry and starts a plugin's [[startup]] processes from that copy at
  # server boot, never from the file on disk: the bundle's pr-watch-focus had
  # carried its startup block for weeks while the registry held an older copy
  # without one, so the hourly poll simply never ran. A root under Herdr's own
  # plugin data directory is the owner's own install and keeps winning. Any
  # other root that is not this bundle is a build path -- a previous tree, an
  # external volume -- which is how image-popup came to be registered from
  # /Volumes/Documents/... . A root that is this bundle is right, but its
  # recorded version and startup section may not be, so those are compared too.
  plan="$("$py" -P - "$res/plugins" "$listed" "$data_dir" <<'PY'
import json, os, re, sys
src, listed, data_dir = sys.argv[1:4]
entries = {}


def collect(node):
    if isinstance(node, dict):
        pid = node.get("plugin_id")
        if isinstance(pid, str) and "plugin_root" in node:
            entries[pid] = node
        for value in node.values():
            collect(value)
    elif isinstance(node, list):
        for value in node:
            collect(value)


try:
    collect(json.load(open(listed, encoding="utf-8")))
except (OSError, ValueError):
    pass

for name in sorted(os.listdir(src)):
    path = os.path.join(src, name)
    if os.path.isfile(os.path.join(path, "lite", "herdr-plugin.toml")):
        path = os.path.join(path, "lite")
    manifest = os.path.join(path, "herdr-plugin.toml")
    if not os.path.isfile(manifest):
        continue
    text = open(manifest, encoding="utf-8").read()
    found_id = re.search(r'^id\s*=\s*"([^"]+)"', text, re.M)
    if not found_id:
        continue
    pid = found_id.group(1)
    version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)
    version = version.group(1) if version else None
    startup = bool(re.search(r'^\[\[startup\]\]', text, re.M))
    entry = entries.get(pid)
    root = entry.get("plugin_root") if entry else None
    if isinstance(root, str) and root.startswith(data_dir + "/"):
        continue
    if isinstance(root, str) and root.startswith(src + "/"):
        if entry.get("version") == version and bool(entry.get("startup")) == startup:
            continue
    print(path)
PY
)"
  while read -r dir; do
    [ -n "$dir" ] || continue
    env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH \
      "$res/bin/herdr" plugin link "$dir" >/dev/null
  done <<<"$plan"
}
