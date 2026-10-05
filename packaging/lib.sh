#!/bin/bash
# Shared by Mash's launcher and the shell inside its panes.
# HOME is never changed. Paths come from the directory service, not $HOME.
# Personal trees are read-only. This file exports variables. It does not write them.

mash_real_home() {
    dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}'
}

# Clear inherited HERDR_* and point every included tool at ~/.mash.
mash_isolate() {
    local home="$1"
    local d="$home/.mash"
    local name
    while IFS='=' read -r name _; do
        case "$name" in
            HERDR_*) unset "$name" ;;
        esac
    done < <(env)
    export XDG_CONFIG_HOME="$d/.config"
    export XDG_STATE_HOME="$d/.local/state"
    export XDG_DATA_HOME="$d/.local/share"
    export XDG_CACHE_HOME="$d/.cache"
    export HERDR_CONFIG_PATH="$d/.config/herdr/config.toml"
    export HERDR_SOCKET_PATH="$d/run/herdr.sock"
    export HERDR_CLIENT_SOCKET_PATH="$d/run/herdr-client.sock"
    export PI_CODING_AGENT_DIR="$d/.pi/agent"
    export GIT_CONFIG_GLOBAL="$d/.config/git/config"
    export GH_CONFIG_DIR="$d/.config/gh"
    export _ZO_DATA_DIR="$d/.local/share/zoxide"
    export ZDOTDIR="$d/.config/zsh"
    export MASH_FRESH_CONFIG_DIR="$d/.config/fresh"
    export MASH_FRESH_DATA_DIR="$d/.local/share/fresh"
    if [ -n "${MASH_BIN:-}" ]; then
        export PATH="$MASH_BIN:$PATH"
    fi
    case "$HERDR_SOCKET_PATH" in
        "$home/.mash/run/"*) ;;
        *)
            echo "Mash refused to use a socket outside ~/.mash/run." >&2
            exit 1
            ;;
    esac
    case "$HERDR_CONFIG_PATH" in
        "$home/.config/herdr/"*)
            echo "Mash refused to use the personal Herdr config." >&2
            exit 1
            ;;
    esac
}

# Flip self-update keys in an existing Mash config. Never replaces the file.
# $1 is the real home. The target must already sit under that home's .mash.
mash_force_updates() {
    local home="$1"
    local d="$home/.mash"
    mash_force_assign "$home" "$d/.config/herdr/config.toml" "version_check" "false"
    mash_force_assign "$home" "$d/.config/herdr/config.toml" "manifest_check" "false"
    mash_force_assign "$home" "$d/.config/ghostty/config" "auto-update" "off"
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
