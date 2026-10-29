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

# An undecided first launch seeds neither optional suite: the wizard writes
# setup/skills-choice only once every page is complete, so a cancelled run
# records no choice and nothing optional is seeded.
mash_skill_enabled() {
  grep -qx "$1=true" "$d/setup/skills-choice" 2>/dev/null
}

mash_seed_pi() {
  local suite path
  set --
  for suite in programming; do
    if ! mash_skill_enabled "$suite"; then
      while IFS= read -r path; do
        [ -n "$path" ] && set -- "$@" "--exclude=/$path"
      done <"$res/defaults/optional-$suite.txt"
    fi
  done
  mkdir -p "$d/pi/agent"
  rsync -a --ignore-existing "$@" "$res/defaults/pi/" "$d/pi/agent/"
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
  mash_skill_enabled programming || return 0
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
  mash_skill_enabled programming || return 0
  [ -f "$src" ] || return 0
  mkdir -p "$d/.hindsight" "$d/.local/bin" "$d/.pg0" "$d/setup"
  [ -f "$d/.hindsight/embed" ] || cp "$src" "$d/.hindsight/embed"
}



# Seed the individual config files that are generated rather than copied: the
# Herdr config names the pane shell and data folder, and pet's config names its
# snippet file, so both are substituted at first launch. Every file is seeded
# only when missing, so a user's own edits are never replaced.
#
#   mash_seed_configs <resource-root> <data-dir>
mash_seed_configs() {
  local res="$1" d="$2" suffix="" version=""
  # The three keymaps are platform-specific: Command chords and the macOS
  # notification app make no sense on Linux, and Ctrl chords would shadow the
  # shell on macOS. The .linux variants sit beside the originals.
  [ "$(uname -s)" = "Darwin" ] || suffix=".linux"
  # The tab bar shows this, so read it once. Empty when the bundle carries no
  # VERSION, which leaves the placeholder visible rather than printing a stray
  # date or a stale number.
  [ -f "$res/VERSION" ] && version="$(tr -d '[:space:]' <"$res/VERSION")"
  mkdir -p "$d/config/herdr" "$d/config/ghostty" "$d/config/zsh" \
    "$d/config/bash" "$d/config/fish" \
    "$d/config/git" "$d/config/pet"
  if [ ! -f "$d/config/herdr/config.toml" ]; then
    sed -e "s#__MASH_SHELL__#$d/bin/mash-shell#g" \
      -e "s#__MASH_CONFIG__#$d/config#g" \
      -e "s#__MASH_VERSION__#$version#g" \
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
  # The pane shell's own startup, one file per dialect: MASH_BIN first,
  # native completion, atuin and Starship. Each is found through a redirect the
  # launcher already establishes -- ZDOTDIR for zsh, XDG_CONFIG_HOME for fish,
  # --rcfile in mash-shell for bash -- so no other code names them. zsh keeps
  # path work in .zshenv because non-interactive pane scripts need it too.
  # STARSHIP_CONFIG points every shell at the one seeded prompt config.
  [ -f "$d/config/starship.toml" ] ||
    cp "$res/defaults/starship.toml" "$d/config/starship.toml"
  for shell_rc in zsh/.zshrc bash/bashrc fish/config.fish; do
    [ -f "$d/config/$shell_rc" ] ||
      cp "$res/defaults/$shell_rc" "$d/config/$shell_rc"
  done
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

# Protect the data directory itself.
#
# ~/.mash holds agent conversation transcripts, logs and credentials, and most of
# those files are written by tools Mash does not own -- Pi writes session
# transcripts mode 0644, Fresh writes one log per editor. Tightening each file is
# neither possible nor necessary: reaching any of them requires +x on this
# directory, so 0700 on the root closes the whole tree whatever mode its contents
# carry. It also has to run on every launch, because `mkdir -p` never changes the
# mode of a directory that already exists -- installs made before this existed
# stay world-traversable until something chmods them.
#
#   mash_protect_data_dir <data-dir>
mash_protect_data_dir() {
  local d="$1"
  mkdir -p "$d" || return 1
  chmod 700 "$d" 2>/dev/null || true
}

# Permission bits of one path, as octal digits, on both platforms.
#
#   mash_file_mode <path>
#
# The two stat flavors disagree on more than spelling, which is what makes a
# naive `stat -f ... || stat -c ...` fallback wrong rather than merely ugly:
# GNU stat reads -f as --file-system, so on Linux it prints a filesystem report
# to STDOUT and exits non-zero. The fallback then appends the real mode to that
# report, and the caller compares a multi-line blob against "700". Every such
# comparison fails on Linux while passing on macOS.
#
# Pick the implementation by asking which one works, rather than by inspecting
# `uname`: a GNU coreutils stat on macOS (Homebrew, nix) answers the GNU form.
mash_file_mode() {
  local path="$1" mode
  if mode="$(stat -c '%a' "$path" 2>/dev/null)" && [ -n "$mode" ]; then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode="$(stat -f '%Lp' "$path" 2>/dev/null)" && [ -n "$mode" ]; then
    printf '%s\n' "$mode"
    return 0
  fi
  return 1
}

# Seed the whole data directory, in the order the launcher needs it: plain
# config first, then the skill payloads that reference it, then the pieces that
# depend on a runtime being in place.
#
#   mash_seed_all <resource-root> <data-dir> <account-home>
mash_seed_all() {
  local res="$1" d="$2" home="$3"
  mash_protect_data_dir "$d"
  mkdir -p \
    "$d/config/herdr" "$d/config/ghostty" "$d/config/git" "$d/config/gh" \
    "$d/config/fresh" "$d/config/zsh" "$d/config/pet" "$d/config/atuin" \
    "$d/config/lazygit" "$d/config/lazydocker" "$d/config/mash" \
    "$d/local/state" "$d/local/share/fresh" "$d/local/share/zoxide" \
    "$d/cache" "$d/pi/agent" "$d/run" "$d/bin"

  # Reconcile before the seed-if-missing helpers below. Otherwise a deleted file
  # would be re-copied from the new defaults before we can compare it to its
  # previous digest, making a legitimate restore look like a user edit.
  [ -x "$res/bin/mash-seed-sync" ] &&
    "$res/bin/mash-seed-sync" "$res" "$d" || true

  mash_seed_configs "$res" "$d"
  mash_seed_missing "$res/defaults/ghostty/themes" "$d/config/ghostty/themes"
  mash_seed_missing "$res/defaults/fresh" "$d/config/fresh"
  mash_seed_pi
  mash_seed_missing "$res/defaults/plugins" "$d/config/herdr/plugins/config"
  mash_write_notifier_config "$res" "$d"
  mash_seed_missing "$res/defaults/atuin" "$d/config/atuin"
  mash_seed_missing "$res/defaults/lazydocker" "$d/config/lazydocker"
  mash_seed_programming_skills
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
