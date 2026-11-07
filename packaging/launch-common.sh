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
  mkdir -p "$dest" || return 1
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
      [ -r "$res/defaults/optional-$suite.txt" ] || return 1
      while IFS= read -r path; do
        [ -n "$path" ] && set -- "$@" "--exclude=/$path"
      done <"$res/defaults/optional-$suite.txt"
    fi
  done
  # The ownership seeder omits this override in Native mode. The legacy
  # seed-if-missing copy runs after it on every launch, so it must omit the
  # same file or the next launch silently puts Mash's Pi keys back.
  if grep -qx 'mode=native' "$d/setup/keybindings-mode" 2>/dev/null; then
    set -- "$@" --exclude=/keybindings.json
  fi
  mkdir -p "$d/pi/agent" || return 1
  rsync -a --ignore-existing "$@" "$res/defaults/pi/" "$d/pi/agent/"
}

# Initial fallback only. The ownership seeder retargets existing untouched
# notifier defaults on relocation; rewriting here would invalidate its digest
# or replace a user's own notifier. Notification clicks use Mash's wrapper.
mash_write_notifier_config() {
  local res="$1" d="$2" cfg tmp src
  cfg="$d/config/herdr/plugins/config/dot.terminal-notifier/config.env"
  [ "${MASH_UNAME:-$(uname -s)}" = "Darwin" ] || return 0
  [ -x "$res/bin/mash-notify" ] || return 0
  [ ! -e "$cfg" ] && [ ! -L "$cfg" ] || return 0
  mkdir -p "$(dirname "$cfg")" || return 1
  tmp="$(mktemp "$cfg.XXXXXX")" || return 1
  src="$res/defaults/plugins/dot.terminal-notifier/config.env"
  if [ -f "$src" ]; then
    sed '/^NOTIFIER=/d' "$src" >"$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf 'NOTIFIER=%s\n' "$res/bin/mash-notify" >>"$tmp" &&
    mv "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
}

# References and the mash-parallel venv live under ~/.mash/config/mash.
# Only a fresh fallback copy is retargeted here. Existing venv files belong to
# the provenance seeder, which preserves user edits and reconciles relocation.
mash_seed_programming_skills() {
  local src venv py cfg current script copied=0
  mash_skill_enabled programming || return 0
  src="$res/defaults/mash-config"
  [ -d "$src" ] || return 0
  mash_seed_missing "$src/references" "$d/config/mash/references" || return 1
  if [ ! -f "$d/config/mash/hindsight-pin" ] && [ -f "$src/hindsight-pin" ]; then
    cp "$src/hindsight-pin" "$d/config/mash/hindsight-pin" || return 1
  fi
  venv="$d/config/mash/venvs/mash-parallel"
  if [ -d "$src/venvs/mash-parallel" ] && [ ! -e "$venv" ] && [ ! -L "$venv" ]; then
    mkdir -p "$d/config/mash/venvs" || return 1
    cp -a "$src/venvs/mash-parallel" "$venv" || return 1
    copied=1
  fi
  py="$res/python/bin/python3"
  # Existing venv entries, including user edits, belong to seed-sync alone.
  if [ "$copied" = 1 ] && [ -d "$venv/bin" ]; then
    [ -x "$py" ] || return 1
    current="$(readlink "$venv/bin/python" 2>/dev/null || true)"
    [ "$current" = "$py" ] || ln -sfn "$py" "$venv/bin/python" || return 1
    current="$(readlink "$venv/bin/python3" 2>/dev/null || true)"
    [ "$current" = "python" ] || ln -sfn python "$venv/bin/python3" || return 1
    if [ -L "$venv/bin/python3.13" ]; then
      current="$(readlink "$venv/bin/python3.13" 2>/dev/null || true)"
      [ "$current" = "python" ] || ln -sfn python "$venv/bin/python3.13" || return 1
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
            ' "$cfg" >"$cfg.tmp" || return 1
      if cmp -s "$cfg.tmp" "$cfg"; then
        rm -f "$cfg.tmp" || return 1
      else
        mv "$cfg.tmp" "$cfg" || return 1
      fi
    fi
    PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 "$py" - "$venv" <<'PY' || return 1
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
  if [ -d "$script" ] && [ -d "$venv" ] && [ ! -e "$script/.venv" ] && [ ! -L "$script/.venv" ]; then
    ln -s "$venv" "$script/.venv" || return 1
  fi
}

# Hindsight keeps its state under the data folder: its warm-start re-exports
# HOME for its process tree alone, so Path.home() resolves here. The config is
# seeded once, and the owner's provider key is added in place — never shipped.
mash_seed_hindsight() {
  local src="$res/defaults/mash-config/hindsight-embed.env"
  mash_skill_enabled programming || return 0
  [ -f "$src" ] || return 0
  mkdir -p "$d/.hindsight" "$d/.local/bin" "$d/.pg0" "$d/setup" || return 1
  [ -f "$d/.hindsight/embed" ] || cp "$src" "$d/.hindsight/embed" || return 1
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
    "$d/config/git" "$d/config/pet" || return 1
  if [ ! -f "$d/config/herdr/config.toml" ]; then
    [ -r "$res/defaults/herdr/config${suffix}.toml" ] || return 1
    sed -e "s#__MASH_SHELL__#$d/bin/mash-shell#g" \
      -e "s#__MASH_CONFIG__#$d/config#g" \
      -e "s#__MASH_VERSION__#$version#g" \
      "$res/defaults/herdr/config${suffix}.toml" >"$d/config/herdr/config.toml" || return 1
  fi
  # The terminal config names herdr-pane by absolute path, so the placeholder is
  # substituted here the same way the Herdr config's shell path is above.
  if [ ! -f "$d/config/ghostty/config" ]; then
    [ -r "$res/defaults/ghostty/config${suffix}" ] || return 1
    sed -e "s#__MASH_HERDR_PANE__#$res/bin/herdr-pane#g" \
      "$res/defaults/ghostty/config${suffix}" >"$d/config/ghostty/config" || return 1
  fi
  # Fresh reads config.json only, so the Linux keymap is seeded under that name.
  # Seeding it before the tree copy below means --ignore-existing leaves it
  # alone instead of replacing it with the macOS keymap.
  if [ -n "$suffix" ] && [ -f "$res/defaults/fresh/config.linux.json" ]; then
    mkdir -p "$d/config/fresh" || return 1
    [ -f "$d/config/fresh/config.json" ] ||
      cp "$res/defaults/fresh/config.linux.json" "$d/config/fresh/config.json" || return 1
  fi
  [ -f "$d/config/zsh/.zshenv" ] ||
    cp "$res/defaults/zsh/.zshenv" "$d/config/zsh/.zshenv" || return 1
  # The pane shell's own startup, one file per dialect: MASH_BIN first,
  # native completion, atuin and Starship. Each is found through a redirect the
  # launcher already establishes -- ZDOTDIR for zsh, XDG_CONFIG_HOME for fish,
  # --rcfile in mash-shell for bash -- so no other code names them. zsh keeps
  # path work in .zshenv because non-interactive pane scripts need it too.
  # STARSHIP_CONFIG points every shell at the one seeded prompt config.
  [ -f "$d/config/starship.toml" ] ||
    cp "$res/defaults/starship.toml" "$d/config/starship.toml" || return 1
  for shell_rc in zsh/.zshrc bash/bashrc fish/config.fish; do
    [ -f "$d/config/$shell_rc" ] ||
      cp "$res/defaults/$shell_rc" "$d/config/$shell_rc" || return 1
  done
  [ -f "$d/config/git/config" ] ||
    cp "$res/defaults/git/config" "$d/config/git/config" || return 1
  # git's default global excludes file lives under the XDG directory Mash pins
  # to ~/.mash/config, so it needs no core.excludesFile entry to be read.
  [ -f "$d/config/git/ignore" ] ||
    cp "$res/defaults/git/ignore" "$d/config/git/ignore" || return 1
  if [ ! -f "$d/config/pet/config.toml" ]; then
    sed "s#__MASH_PET_SNIPPET__#$d/config/pet/snippet.toml#" \
      "$res/defaults/pet/config.toml" >"$d/config/pet/config.toml" || return 1
  fi
  [ -f "$d/config/pet/snippet.toml" ] ||
    cp "$res/defaults/pet/snippet.toml" "$d/config/pet/snippet.toml" || return 1
  # The in-product cheat sheet lists chords, so it follows the platform too.
  if [ -n "$suffix" ] &&
    [ -f "$res/defaults/pi/extensions/keybindings-quickref.linux.txt" ]; then
    mkdir -p "$d/pi/agent/extensions" || return 1
    [ -f "$d/pi/agent/extensions/keybindings-quickref.txt" ] ||
      cp "$res/defaults/pi/extensions/keybindings-quickref.linux.txt" \
        "$d/pi/agent/extensions/keybindings-quickref.txt" || return 1
  fi

  # The pane shell itself is copied out of the read-only tree so a package
  # upgrade does not change the shell underneath a running pane.
  cp "$res/bin/lib.sh" "$d/bin/lib.sh" || return 1
  cp "$res/bin/launch-common.sh" "$d/bin/launch-common.sh" || return 1
  cp "$res/bin/mash-shell" "$d/bin/mash-shell" || return 1
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
  mash_protect_data_dir "$d" || return 1
  mkdir -p \
    "$d/config/herdr" "$d/config/ghostty" "$d/config/git" "$d/config/gh" \
    "$d/config/fresh" "$d/config/zsh" "$d/config/pet" "$d/config/atuin" \
    "$d/config/lazygit" "$d/config/lazydocker" "$d/config/mash" \
    "$d/local/state" "$d/local/share/fresh" "$d/local/share/zoxide" \
    "$d/cache" "$d/pi/agent" "$d/run" "$d/bin" || return 1

  # Reconcile before the seed-if-missing helpers below. Otherwise a deleted file
  # would be re-copied from the new defaults before we can compare it to its
  # previous digest, making a legitimate restore look like a user edit.
  if [ -x "$res/bin/mash-seed-sync" ]; then
    "$res/bin/mash-seed-sync" "$res" "$d" || return 1
  fi

  mash_seed_configs "$res" "$d" || return 1
  mash_seed_missing "$res/defaults/ghostty/themes" "$d/config/ghostty/themes" || return 1
  mash_seed_missing "$res/defaults/fresh" "$d/config/fresh" || return 1
  [ -f "$d/config/fresh/config.json" ] || return 1
  mash_seed_pi || return 1
  # Render a missing notifier before the raw tree copy can fill that path.
  mash_write_notifier_config "$res" "$d" || return 1
  mash_seed_missing "$res/defaults/plugins" "$d/config/herdr/plugins/config" || return 1
  mash_seed_missing "$res/defaults/atuin" "$d/config/atuin" || return 1
  mash_seed_missing "$res/defaults/lazydocker" "$d/config/lazydocker" || return 1
  mash_seed_missing "$res/defaults/herdr-auto-title" "$d/config/herdr-auto-title" || return 1
  mash_seed_programming_skills || printf 'Mash: optional Programming Skills seeding failed; continuing.\n' >&2
  mash_seed_hindsight || printf 'Mash: optional memory seeding failed; continuing.\n' >&2
  return 0
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
