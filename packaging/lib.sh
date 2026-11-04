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
  # One prompt config for bash, zsh and fish; Starship's session/cache files
  # stay in the data folder rather than the account's ~/.cache.
  export STARSHIP_CONFIG="$d/config/starship.toml"
  export STARSHIP_CACHE="$d/cache/starship"
  export HERDR_CONFIG_PATH="$d/config/herdr/config.toml"
  # One Mash, one Herdr server. HERDR_SESSION stays unset: Herdr treats that as
  # its unnamed session, whose layout is ~/.mash/config/herdr/session.json.
  export HERDR_SOCKET_PATH="$d/run/herdr.sock"
  export HERDR_CLIENT_SOCKET_PATH="$d/run/herdr-client.sock"
  unset HERDR_SESSION
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
  # Mash's own config tree: the Hindsight pin, shared references and the
  # mash-parallel venv live here, and tools fall back to the real
  # ~/.config/mash when it is absent.
  export MASH_CONFIG_DIR="$d/config/mash"
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
  # python3, fresh, lazygit, lazydocker and pet. Mash-owned npm shims (including
  # agent-browser) are in ~/.mash/bin; CUA Driver is in ~/.local/bin. Pinning
  # MASH_BIN to the front makes "Mash runs the version it ships" a property of
  # this function rather than of the caller's environment. The programs that are host-provided on
  # purpose (fd, rg, eza, fzf, bat, git) are not shipped by Mash at all, so
  # the host tier is what reaches them. gh is bundled, so Mash's pinned gh wins
  # over a Homebrew one inside Mash; its login stays in GH_CONFIG_DIR either way.
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
  # CUA Driver there, not Homebrew. ~/.bun/bin is next for
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
  case "$HERDR_SOCKET_PATH" in
  "$home/.mash/run/herdr.sock") ;;
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

mash_force_updates() {
  local home="$1"
  local d="$home/.mash"
  mash_force_assign "$home" "$d/config/herdr/config.toml" "version_check" "false" || return 1
  mash_force_assign "$home" "$d/config/herdr/config.toml" "manifest_check" "false" || return 1
  mash_force_assign "$home" "$d/config/ghostty/config" "auto-update" "off" || return 1
  # Fresh defaults both of these to true: it would check GitHub for a release and
  # offer to replace itself, which swaps Mash's patched build for an upstream
  # binary that ignores MASH_FRESH_CONFIG_DIR.
  mash_force_json_bool "$home" "$d/config/fresh/config.json" "check_for_updates" "false" || return 1
  mash_force_json_bool "$home" "$d/config/fresh/config.json" "self_update" "false" || return 1
}

# Change only one top-level JSON boolean, preserving other properties and mode.
# Invalid or unsafe files are refused, and an already-correct value is a no-op.
# $1 home, $2 file, $3 key, $4 true or false.
mash_force_json_bool() {
  local home="$1" file="$2" key="$3" value="$4" python
  case "$file" in
  "$home/.mash/"*) ;;
  *) echo "Mash refused to edit $file." >&2; return 1 ;;
  esac
  [ -e "$file" ] || [ -L "$file" ] || return 0
  python="$(dirname "${BASH_SOURCE[0]}")/../python/bin/python3"
  [ -x "$python" ] || python="$(command -v python3)" || return 1
  PYTHONDONTWRITEBYTECODE=1 "$python" -I -B - "$home/.mash" "$file" "$key" "$value" <<'PY'
import json
import os
import stat
import sys
import tempfile


def reject_constant(value):
    raise ValueError("invalid JSON constant")


def strip_jsonc(text):
    """Drop // and /* */ comments and trailing commas, leaving strings intact.

    Fresh parses its config as the JSONC superset (see its own parseJsonc), so a
    comment a person added to config.json is legal input, not a broken file.
    """
    out = []
    i, n = 0, len(text)
    in_string = escaped = False
    while i < n:
        char = text[i]
        if in_string:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                raise ValueError("unterminated comment")
            i = end + 2
            continue
        if char == ",":
            # A comma is a trailing comma when only whitespace and comments
            # separate it from the closing bracket that ends the container.
            j = i + 1
            while j < n:
                if text[j] in " \t\r\n":
                    j += 1
                elif text.startswith("//", j):
                    end = text.find("\n", j)
                    j = n if end < 0 else end
                elif text.startswith("/*", j):
                    end = text.find("*/", j + 2)
                    if end < 0:
                        raise ValueError("unterminated comment")
                    j = end + 2
                else:
                    break
            if j < n and text[j] in "}]":
                i += 1
                continue
        out.append(char)
        i += 1
    return "".join(out)


root, path, key, value = sys.argv[1:]
tmp = None
try:
    root = os.path.realpath(root)
    if os.path.commonpath((root, os.path.realpath(os.path.dirname(path)))) != root:
        raise ValueError("unsafe path")
    mode = os.lstat(path)
    if not stat.S_ISREG(mode.st_mode) or mode.st_size > 4 * 1024 * 1024:
        raise ValueError("unsafe config")
    if value not in ("true", "false"):
        raise ValueError("not a boolean")
    with open(path, encoding="utf-8") as source:
        text = source.read()
    try:
        data = json.loads(text, parse_constant=reject_constant)
    except ValueError:
        # Only reachable for a file Mash does not understand at all; refusing
        # keeps the user's bytes rather than replacing them with a guess.
        data = json.loads(strip_jsonc(text), parse_constant=reject_constant)
    if not isinstance(data, dict):
        raise ValueError("not an object")
    wanted = value == "true"
    if data.get(key) is wanted:
        sys.exit(0)
    data[key] = wanted
    fd, tmp = tempfile.mkstemp(prefix=".mash-force-", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as target:
        os.fchmod(target.fileno(), stat.S_IMODE(mode.st_mode))
        json.dump(data, target, indent=2, allow_nan=False)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
    os.replace(tmp, path)
except (OSError, ValueError):
    # The launcher surfaces this in its alert, so name the file and the remedy:
    # the user cannot act on "settings" alone.
    print(
        f"Mash could not safely update {path}; the file was kept."
        " Fix its JSON, or delete it so Mash recreates it.",
        file=sys.stderr,
    )
    sys.exit(1)
finally:
    if tmp is not None and os.path.exists(tmp):
        os.unlink(tmp)
PY
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
  tmp="$(mktemp "$home/.mash/force.XXXXXX")" || return 1
  awk -v key="$key" -v value="$value" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = " value; found=1; next }
        { print }
        END { if (!found) print key " = " value }
    ' "$file" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
