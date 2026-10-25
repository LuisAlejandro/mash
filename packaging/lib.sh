#!/bin/bash
# Shared by Mash's launcher and the shell inside its panes.
# HOME is never changed. Personal trees are read-only.
# This file exports variables. It does not write them.

# The account database, not $HOME: a Mash launched from another environment, or
# with HOME overridden by a tool, must still resolve the real home. macOS reads
# the directory service; Linux reads NSS through getent, which also answers for
# LDAP and SSSD accounts. Both fall back to $HOME rather than guessing a path.
mash_real_home() {
  local home=""
  if command -v dscl >/dev/null 2>&1; then
    home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  fi
  if [ -z "$home" ] && command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
  fi
  printf '%s\n' "${home:-${HOME:-}}"
}

# The account's login shell, by the same rules: the directory service on macOS,
# NSS elsewhere, and $SHELL as the fallback.
mash_real_shell() {
  local shell=""
  if command -v dscl >/dev/null 2>&1; then
    shell="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}')"
  fi
  if [ -z "$shell" ] && command -v getent >/dev/null 2>&1; then
    shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
  fi
  printf '%s\n' "${shell:-${SHELL:-/bin/sh}}"
}

# The Mash instance a launch or a pane belongs to. "default" is the instance
# every Mash had before instances existed, and it keeps the original paths:
# ~/.mash/run/herdr.sock and the unnamed Herdr session, whose layout is
# ~/.mash/config/herdr/session.json. A named instance gets its own socket
# directory and its own Herdr session, which is what gives it its own
# workspaces and tabs while every setting stays shared.
#
# The name cannot travel in a HERDR_* variable: mash_isolate clears all of
# them below, precisely so a Mash started from a personal Herdr's pane cannot
# inherit that server. MASH_INSTANCE is therefore the carrier, and
# HERDR_SESSION is derived from it after the purge.
mash_instance_name() {
  local name="${MASH_INSTANCE:-default}"
  # Anything outside [A-Za-z0-9._-] could escape the run directory or produce a
  # session name Herdr rejects, so an unusable name falls back rather than
  # failing a launch the user cannot otherwise recover from.
  case "$name" in
  "" | *[!A-Za-z0-9._-]*) name="default" ;;
  esac
  printf '%s\n' "$name"
}

# Where an instance records the pid of the window that owns it.
mash_instance_window_file() {
  # Each name is assigned from a positional, never from a sibling in the same
  # `local` statement: within one declaration an earlier name is not yet
  # assigned when a later one expands it, so `local home="$1" d="$home/.mash"`
  # silently yields "/.mash". That form made every claim fail its mkdir and
  # fall back to the default instance -- indistinguishable from the clone bug
  # this feature removes.
  local d="$1/.mash" instance="$2"
  if [ "$instance" = "default" ]; then
    printf '%s\n' "$d/run/window.pid"
  else
    printf '%s\n' "$d/run/$instance/window.pid"
  fi
}

# Whether an instance already has a live window. A marker naming a pid that is
# gone is stale -- a crash, a kill -9, a reboot -- and the instance is free.
mash_instance_is_taken() {
  local home="$1" instance="$2" file pid
  file="$(mash_instance_window_file "$home" "$instance")"
  [ -f "$file" ] || return 1
  pid="$(cat "$file" 2>/dev/null)"
  case "$pid" in
  "" | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# The first instance with no live window: "default", then 2, 3, ...
#
# Clicking the icon twice in quick succession runs two of these at once, so the
# claim has to be atomic or both would pick the same free instance and the
# second window would clone the first -- the very bug this feature removes.
# `mkdir` is the atomic primitive that exists everywhere: it fails if the
# directory is already there, and unlike flock(1) it is on macOS too.
mash_claim_instance() {
  local home="$1" pid="$2" instance n=1 lock
  # Separate statement: see mash_instance_window_file.
  local d="$home/.mash"
  mkdir -p "$d/run"
  local holder
  while [ "$n" -le 32 ]; do
    if [ "$n" -eq 1 ]; then instance="default"; else instance="$n"; fi
    lock="$d/run/.claim-$instance"
    if mkdir "$lock" 2>/dev/null; then
      if mash_instance_is_taken "$home" "$instance"; then
        rmdir "$lock" 2>/dev/null
      else
        # Hold the instance against a concurrent claim until the window marker
        # is written. Without this the window between "found free" and "marked
        # taken" is wide enough for a second click to pick the same instance.
        printf '%s\n' "$pid" >"$lock/pid"
        printf '%s\n' "$instance"
        return 0
      fi
    elif [ -f "$lock/pid" ]; then
      # Someone else is mid-claim. Theirs if they are alive; otherwise the lock
      # outlived its claimant and must not strand the instance forever.
      holder="$(cat "$lock/pid" 2>/dev/null)"
      case "$holder" in
      "" | *[!0-9]*) rm -rf "$lock" 2>/dev/null && continue ;;
      esac
      kill -0 "$holder" 2>/dev/null || {
        rm -rf "$lock" 2>/dev/null
        continue
      }
    fi
    n=$((n + 1))
  done
  # Every instance is busy. The default is the honest answer: the user gets the
  # clone window they get today rather than no window at all.
  printf 'default\n'
}

# Record this window as the owner of its instance and release the claim lock.
mash_mark_instance_window() {
  local home="$1" instance="$2" pid="$3" file
  file="$(mash_instance_window_file "$home" "$instance")"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$pid" >"$file"
  rm -rf "$home/.mash/run/.claim-$instance" 2>/dev/null || true
}

# Drop the marker when the window exits, but only if it is still ours: a
# relaunch may already have claimed the instance, and removing its marker would
# hand the same instance to the next click while that window is still open.
mash_release_instance_window() {
  local home="$1" instance="$2" pid="$3" file
  file="$(mash_instance_window_file "$home" "$instance")"
  [ -f "$file" ] || return 0
  [ "$(cat "$file" 2>/dev/null)" = "$pid" ] || return 0
  rm -f "$file" 2>/dev/null || true
}

# Clear inherited HERDR_* and point every included tool at ~/.mash.
#
# $2 = "pane" is the pane shell's call. It keeps the per-pane variables the
# owning Herdr server injects (HERDR_ENV, HERDR_PANE_ID, HERDR_BIN_PATH,
# HERDR_WORKSPACE_ID, HERDR_TAB_ID). Everything running inside the pane needs
# them to identify its own pane, and two restore paths depend on that: pi's
# Herdr integration only reports its session while HERDR_ENV is 1, and
# herdr-fresh-pane resolves its pane from HERDR_PANE_ID before reporting its
# resume command. Without those reports a server restart brings the pane back
# as a plain shell. The launch callers (mash, herdr-pane) keep clearing them,
# so a Mash started from a pane of a personal Herdr cannot attach to that
# server. The socket, client-socket, and config paths are replaced either way,
# so a pane never reaches outside ~/.mash.
mash_isolate() {
  local home="$1"
  local keep_pane="${2:-}"
  local d="$home/.mash"
  local name value
  while IFS='=' read -r name value; do
    case "$name" in
    HERDR_ENV | HERDR_PANE_ID | HERDR_BIN_PATH | HERDR_WORKSPACE_ID | HERDR_TAB_ID)
      if [ "$keep_pane" = pane ]; then
        continue
      fi
      ;;
    HERDR_*) ;;
    *) continue ;;
    esac
    unset "$name"
  done < <(env)
  export XDG_CONFIG_HOME="$d/config"
  export XDG_STATE_HOME="$d/local/state"
  export XDG_DATA_HOME="$d/local/share"
  export XDG_CACHE_HOME="$d/cache"
  export HERDR_CONFIG_PATH="$d/config/herdr/config.toml"
  # The instance decides the socket and the Herdr session; every path above and
  # below is shared by all instances, which is what "separate workspaces, one
  # set of settings" means here.
  #
  # Both variables are set on purpose. HERDR_SOCKET_PATH wins over
  # HERDR_SESSION in Herdr 0.9.3, so naming the session alone would leave every
  # instance on the same socket; and the socket alone would leave them sharing
  # one session.json, where two servers overwrite each other's workspaces.
  local instance
  instance="$(mash_instance_name)"
  export MASH_INSTANCE="$instance"
  if [ "$instance" = "default" ]; then
    export HERDR_SOCKET_PATH="$d/run/herdr.sock"
    export HERDR_CLIENT_SOCKET_PATH="$d/run/herdr-client.sock"
    # Herdr treats the name "default" as the unnamed session, so exporting it
    # would be a no-op; leaving it unset keeps the default instance byte-for-byte
    # what it was before instances existed.
    unset HERDR_SESSION
  else
    mkdir -p "$d/run/$instance"
    export HERDR_SOCKET_PATH="$d/run/$instance/herdr.sock"
    export HERDR_CLIENT_SOCKET_PATH="$d/run/$instance/herdr-client.sock"
    export HERDR_SESSION="$instance"
  fi
  export PI_CODING_AGENT_DIR="$d/pi/agent"
  # pi packages the user installs, like pi's own agent directory. pi resolves
  # them from `<agentDir>/npm/node_modules` (getManagedNpmInstallPath), so
  # `pi install` run in a Mash pane lands here and not in ~/.pi/agent: this is
  # writable, outside the signed bundle, and survives an app update.
  #
  # PI_HOME is pi's package-integration environment variable and is what a
  # plugin that cannot call pi's getAgentDir() uses to find its agent directory.
  # pi-omniroute-sync defaults to ~/.pi/agent when it is unset, which would put
  # a Mash plugin's settings and API key into the owner's own pi and write their
  # models.json.
  export PI_HOME="$d/pi/agent"
  # pi checks pi.dev for a newer release on startup. Mash ships and pins one pi,
  # and `pi update` would replace it inside the signed bundle, so the check only
  # advertises an update that must not be taken. Any non-empty value disables
  # it; updates stay available through `pi update` by hand.
  export PI_SKIP_VERSION_CHECK="1"
  export GIT_CONFIG_GLOBAL="$d/config/git/config"
  export GH_CONFIG_DIR="$d/config/gh"
  export _ZO_DATA_DIR="$d/local/share/zoxide"
  export ZDOTDIR="$d/config/zsh"
  export MASH_FRESH_CONFIG_DIR="$d/config/fresh"
  export MASH_FRESH_DATA_DIR="$d/local/share/fresh"
  # The design stack. `mds` and every design skill read these, and mds falls
  # back to the real ~/.config/mash and ~/.local/share when they are absent —
  # which would put compose state and Penpot secrets outside the data folder.
  export MASH_CONFIG_DIR="$d/config/mash"
  export MASH_DESIGN_STACK="$d/local/share/mash/design"
  # Hindsight resolves its own state through Path.home(), and Mash never moves
  # HOME. The warm-start script re-exports HOME for the Hindsight tree alone;
  # this is the path it derives from.
  export MASH_DATA_DIR="$d"
  # Hindsight downloads an ONNX embedding model and a FlashRank reranker on
  # first start. Both cache here instead of the real home, and FlashRank's
  # default of /tmp is not a safe cache for a daemon that outlives the session.
  export HF_HOME="$d/cache/huggingface"
  export HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR="$d/cache/flashrank"
  # Playwright downloads a browser per install. Keep it in the data folder so
  # Mash never shares or disturbs the user's own Playwright cache.
  export PLAYWRIGHT_BROWSERS_PATH="$d/cache/ms-playwright"
  # `pi install` runs npm, and HOME is never changed, so npm would cache every
  # download in the owner's real ~/.npm. A Mash install should write only under
  # ~/.mash, so the cache goes here. Nothing is lost if it is empty: it is a
  # cache, and the same packages reinstall from the registry.
  export npm_config_cache="$d/cache/npm"
  # PATH is rebuilt explicitly, in three tiers: Mash's own program
  # directories, then the host directories the shipped configs name, then
  # whatever was inherited. Mash's own programs are never resolved by bare name
  # against a host directory, because nearly every one of them has a twin a user
  # may have installed -- /opt/homebrew/bin carries pi, herdr, node, npm, npx,
  # python3, fresh, lazygit, lazydocker and pet, and ~/.local/bin is where the
  # wizard puts agent-browser and CUA Driver. Pinning MASH_BIN to the front
  # makes "Mash runs the version it ships" a property of this function rather
  # than of the caller's environment. The programs that are host-provided on
  # purpose (fd, rg, eza, fzf, bat, git, gh) are not shipped by Mash at all, so
  # the host tier is what reaches them.
  #
  # The tiers are built here rather than by appending MASH_BIN to the inherited
  # PATH. That older form made the order depend on who called last: a host
  # directory absent from the inherited PATH was prepended ahead of Mash's, so
  # a pane whose server had lost Mash's own directories on PATH ran Homebrew's
  # pi (0.99.1) instead of the pinned one (1.1.0), silently.
  #
  # The host tier is not optional. A Dock launch hands the app the minimal PATH
  # macOS gives a GUI process, and the wizard installs eza for the sesh preview
  # and fzf, bat and rg for Fresh. The sesh picker runs its configured preview
  # through `sh -lc` on the inherited PATH, so without the tier it fails with
  # "exit status 127". ~/.local/bin leads the tier because the wizard puts
  # agent-browser and CUA Driver there, not Homebrew. ~/.bun/bin is next for
  # the same reason: bun is not a Homebrew package, the bun installer puts
  # bun and bunx there (and a Bash-it shim points the name at it), and nothing
  # else in this file could reach them -- a `bun install` in a pane would write
  # a program the pane cannot then run by name. Skipped when the directory is
  # absent, like every other entry here.
  #
  # Elements are split with `read`, not by word-splitting, so a Mash installed
  # under a path with spaces still yields whole entries, and empty elements are
  # dropped rather than kept as the current directory. A colon list joined
  # without its separator once produced entries like
  # "/Users/me/.mash/bin/opt/homebrew/bin", which quietly removed
  # /opt/homebrew/bin from every pane and took fd, rg, eza, fzf, bat and every
  # formatter or language server Fresh launches by bare name with it. That is
  # why packaging/tests/test_mash_isolate.sh asserts exact element membership
  # and rejects joined elements instead of matching substrings.
  local pinned="" host="" rest="" seen=":" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$seen" in *":$dir:"*) continue ;; esac
    seen="$seen$dir:"
    pinned="$pinned$dir:"
  done < <(printf '%s\n' "${MASH_BIN:-}" | tr ':' '\n')
  for dir in "$home/.local/bin" "$home/.bun/bin" /opt/homebrew/bin /usr/local/bin /opt/homebrew/sbin /usr/local/sbin; do
    [ -d "$dir" ] || continue
    case "$seen" in *":$dir:"*) continue ;; esac
    seen="$seen$dir:"
    host="$host$dir:"
  done
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$seen" in *":$dir:"*) continue ;; esac
    seen="$seen$dir:"
    rest="$rest$dir:"
  done < <(printf '%s\n' "${PATH:-}" | tr ':' '\n')
  # Each tier carries a trailing separator while it is being built; the last one
  # has to lose it. A PATH ending in ":" has an empty element, which every
  # shell reads as the current directory.
  local joined="$pinned$host$rest"
  joined="${joined%:}"
  if [ -n "$joined" ]; then
    export PATH="$joined"
  fi
  # Both shapes live under ~/.mash/run: the default instance's socket sits
  # directly in it, a named instance's in its own subdirectory.
  case "$HERDR_SOCKET_PATH" in
  "$home/.mash/run/herdr.sock" | "$home/.mash/run/$instance/herdr.sock") ;;
  *)
    echo "Mash refused to use a socket outside ~/.mash/run." >&2
    exit 1
    ;;
  esac
  case "$HERDR_CONFIG_PATH" in
  "$home/.config/herdr/"*)
    echo "Mash refused to use a non-Mash Herdr config." >&2
    exit 1
    ;;
  esac
}

# Flip self-update keys in an existing Mash config. Never replaces the file.
# $1 is the real home. The target must already sit under that home's .mash.
# Point the terminal's own New Window at herdr-pane, in an install that already
# has a config from before the key existed, and after an app update moved the
# bundle. Without it, File > New Window opens a bare shell in an old install and
# a stale path in a moved one. $2 is the resource root.
mash_force_window_command() {
  local home="$1" res="$2"
  [ -n "$res" ] || return 0
  mash_force_assign "$home" "$home/.mash/config/ghostty/config" \
    "command" "$res/bin/herdr-pane"
  # A second, empty instance takes its first workspace from the window's
  # directory, so this must not be left to Ghostty's launch detection in an
  # install whose config predates the key.
  mash_force_assign "$home" "$home/.mash/config/ghostty/config" \
    "working-directory" "home"
}

mash_force_updates() {
  local home="$1"
  local d="$home/.mash"
  mash_force_assign "$home" "$d/config/herdr/config.toml" "version_check" "false"
  mash_force_assign "$home" "$d/config/herdr/config.toml" "manifest_check" "false"
  mash_force_assign "$home" "$d/config/ghostty/config" "auto-update" "off"
  # Fresh defaults both of these to true: it would check GitHub for a release and
  # offer to replace itself, which swaps Mash's patched build for an upstream
  # binary that ignores MASH_FRESH_CONFIG_DIR.
  mash_force_json_bool "$home" "$d/config/fresh/config.json" "check_for_updates" "false"
  mash_force_json_bool "$home" "$d/config/fresh/config.json" "self_update" "false"
}

# Force one top-level boolean in a pretty-printed JSON config. Never replaces the
# file: it rewrites the key's line, or adds it after the opening brace when it is
# absent. Mash seeds these files pretty-printed, so one key per line holds.
# $1 home, $2 file, $3 key, $4 true or false.
mash_force_json_bool() {
  local home="$1"
  local file="$2"
  local key="$3"
  local value="$4"
  local tmp
  case "$file" in
  "$home/.mash/"*) ;;
  *)
    echo "Mash refused to edit $file." >&2
    exit 1
    ;;
  esac
  [ -f "$file" ] || return 0
  tmp="$(mktemp "$home/.mash/force.XXXXXX")"
  awk -v key="$key" -v value="$value" '
        # The key is added below the opening brace only when it is missing
        # anywhere, so the whole file is read before deciding. Streaming would
        # insert a duplicate before reaching the existing key line.
        BEGIN {
            re = "^[[:space:]]*\"" key "\"[[:space:]]*:"
            brace = "^[[:space:]]*[{][[:space:]]*$"
            has = 0
        }
        { lines[NR] = $0; if ($0 ~ re) has = 1 }
        END {
            if (has) {
                for (i = 1; i <= NR; i++) {
                    if (lines[i] ~ re) {
                        match(lines[i], /^[[:space:]]*/)
                        out = substr(lines[i], 1, RLENGTH) "\"" key "\": " value
                        if (lines[i] ~ /,[[:space:]]*$/) out = out ","
                        print out
                    } else {
                        print lines[i]
                    }
                }
                exit
            }
            inserted = 0
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (!inserted && lines[i] ~ brace) {
                    match(lines[i], /^[[:space:]]*/)
                    print substr(lines[i], 1, RLENGTH) "  \"" key "\": " value ","
                    inserted = 1
                }
            }
        }
    ' "$file" >"$tmp"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi
}

mash_force_assign() {
  local home="$1"
  local file="$2"
  local key="$3"
  local value="$4"
  local tmp
  case "$file" in
  "$home/.mash/"*) ;;
  *)
    echo "Mash refused to edit $file." >&2
    exit 1
    ;;
  esac
  [ -f "$file" ] || return 0
  tmp="$(mktemp "$home/.mash/force.XXXXXX")"
  awk -v key="$key" -v value="$value" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = " value; found=1; next }
        { print }
        END { if (!found) print key " = " value }
    ' "$file" >"$tmp"
  mv "$tmp" "$file"
}
