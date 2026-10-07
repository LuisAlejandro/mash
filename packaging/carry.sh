#!/bin/bash
# Fresh, plugins, fonts, and pins for packaging/build.sh.
# Sourced by that script. Writes only under the repo dist/ and, once, pins.txt.

mash_pins_text() {
    cat <<'EOF'
ghostty 1.3.1
herdr 0.9.3
fresh 0.5.1
pi 0.99.1
node 24.16.0
python 3.13.16
git 2.56.0
lazygit 0.65.1
lazydocker 0.25.2
pet 1.0.1
zoxide 0.10.0
eza 0.23.5
fzf 0.67.0
fd 10.5.0
bat 0.26.1
rg 15.2.0
jq 1.8.1
gh 2.95.0
delta 0.19.2
atuin 18.23.0
gopls 0.23.0
rust-analyzer 2026-09-27
marksman 2026-02-08
texlab 5.26.0
bash-language-server 5.8.1
typescript-language-server 6.0.1
yaml-language-server 1.24.0
tailwindcss-language-server 0.16.0
svelte-language-server 0.18.4
vscode-langservers-extracted 4.10.0
python-lsp-server 1.15.0
pi-subagents 0.76.0
pi-mcp-adapter 5.0.0
pi-ask-user 0.16.0
pi-monokai-pro 0.2.0
pi-plan-mode 0.4.8
pi-web-search 1.6.0
shfmt 3.14.1
prettier 3.9.9
prettier-plugin-svelte 4.1.1
annotate 0.8.0
herdr-terminal-notifier 0.1.0
fullerzz.sesh 0.14.0
herdr.auto-title 0.9.1
persiyanov.reviewr 0.39.0
herdr-workspace 0.1.2
telescope 0.1.2
ray.plugin-manager 0.5.0
mash-programming-skills 0.5.14
EOF
}

mash_pins_check() {
    local pins="$root/packaging/pins.txt"
    [ -f "$pins" ] || return 0
    if ! mash_pins_text | cmp -s - "$pins"; then
        echo "packaging/pins.txt does not match this build. Leaving dist/Mash.app in place." >&2
        exit 1
    fi
}

mash_require_sources() {
    local name font plugins="$root/packaging/plugins"
    for name in cache-hit dev-tab fingers fork-from-message herdr-orchestration pr-watch-focus herdr-workspace telescope; do
        [ -f "$plugins/$name/herdr-plugin.toml" ] || {
            echo "missing plugin source $plugins/$name" >&2
            exit 1
        }
    done
    [ -f "$root/packaging/helpers/herdr-dev-tab-fill" ] || {
        echo "missing helper herdr-dev-tab-fill" >&2
        exit 1
    }
    for font in \
        "MesloLGS NF Regular.ttf" \
        "MesloLGS NF Bold.ttf" \
        "MesloLGS NF Italic.ttf" \
        "MesloLGS NF Bold Italic.ttf"
    do
        [ -f "$root/packaging/fonts/$font" ] || {
            echo "missing font $font" >&2
            exit 1
        }
    done
    [ -f "$root/packaging/patches/fresh-config-dir.patch" ] || {
        echo "missing Fresh patch" >&2
        exit 1
    }
    [ -f "$root/packaging/patches/herdr-workspace-absolute-path.patch" ] || {
        echo "missing workspace patch" >&2
        exit 1
    }
    [ -f "$root/packaging/uninstall" ] || { echo "missing uninstall" >&2; exit 1; }
}

mash_copy_tree() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    tar -C "$src" \
        --exclude target \
        --exclude .git \
        --exclude .beads \
        --exclude .codex \
        --exclude .claude \
        --exclude __pycache__ \
        --exclude node_modules \
        -cf - . | tar -C "$dest" -xf -
}

mash_cargo() {
    local manifest="$1"
    local name="$2"
    env CARGO_HOME="$root/dist/.cargo" \
        CARGO_TARGET_DIR="$root/dist/.cargo-target/$name" \
        cargo build --release --manifest-path "$manifest"
}

mash_build_fresh() {
    local tarball="$work/fresh.tar.gz"
    curl -fL --retry 2 --max-time 300 -o "$tarball" \
        "https://github.com/sinelaw/fresh/archive/refs/tags/v0.5.1.tar.gz"
    tar -xzf "$tarball" -C "$work"
    local src="$work/fresh-0.5.1"
    grep -q 'version = "0.5.1"' "$src/Cargo.toml"
    if ! patch -p1 -d "$src" <"$root/packaging/patches/fresh-config-dir.patch"; then
        echo "Fresh patch did not apply. Leaving dist/Mash.app in place." >&2
        exit 1
    fi
    mash_cargo "$src/Cargo.toml" fresh
    local bin="$root/dist/.cargo-target/fresh/release/fresh"
    [ -x "$bin" ] || { echo "Fresh binary was not produced." >&2; exit 1; }
    mkdir -p "$app/Contents/Resources/libexec"
    cp "$bin" "$app/Contents/Resources/libexec/fresh"
    chmod 755 "$app/Contents/Resources/libexec/fresh"
    cat >"$app/Contents/Resources/bin/fresh" <<'EOF'
#!/bin/bash
# Refuse to start unless Mash pointed Fresh at ~/.mash.
set -euo pipefail
cfg="${MASH_FRESH_CONFIG_DIR:-}"
data="${MASH_FRESH_DATA_DIR:-}"
case "$cfg" in
    /*/.mash/*) ;;
    *) echo "Fresh refused to start." >&2; exit 1 ;;
esac
case "$data" in
    /*/.mash/*) ;;
    *) echo "Fresh refused to start." >&2; exit 1 ;;
esac
[ -f "$cfg/config.json" ] || { echo "Fresh seed is not in place." >&2; exit 1; }
exec "$(cd "$(dirname "$0")/../libexec" && pwd)/fresh" "$@"
EOF
    chmod 755 "$app/Contents/Resources/bin/fresh"
    tar -C "$work" --exclude target --exclude .git -czf \
        "$root/dist/fresh-0.5.1-patched.tar.gz" fresh-0.5.1
}

mash_go() {
    local dir="$1"
    shift
    env GOCACHE="$work/gocache" GOMODCACHE="$work/gomod" GOPATH="$work/gopath" \
        GO111MODULE=on go build "$@"
    (cd "$dir" && true)
}

mash_build_plugins() {
    local plugins="$app/Contents/Resources/plugins"
    local src="$root/packaging/plugins"
    mkdir -p "$plugins" "$work/src"
    local name
    for name in cache-hit dev-tab fingers fork-from-message herdr-orchestration pr-watch-focus; do
        mash_copy_tree "$src/$name" "$plugins/$name"
    done

    mash_copy_tree "$src/herdr-workspace" "$plugins/herdr-workspace"
    if ! patch -p1 -d "$plugins/herdr-workspace" \
        <"$root/packaging/patches/herdr-workspace-absolute-path.patch"; then
        echo "workspace patch did not apply. Leaving dist/Mash.app in place." >&2
        exit 1
    fi
    mash_cargo "$plugins/herdr-workspace/Cargo.toml" herdr-workspace
    mkdir -p "$plugins/herdr-workspace/bin"
    cp "$root/dist/.cargo-target/herdr-workspace/release/herdr-workspace" \
        "$plugins/herdr-workspace/bin/herdr-workspace"
    chmod 755 "$plugins/herdr-workspace/bin/herdr-workspace"

    mash_copy_tree "$src/telescope" "$plugins/telescope"
    mash_cargo "$plugins/telescope/Cargo.toml" telescope
    mkdir -p "$plugins/telescope/bin"
    cp "$root/dist/.cargo-target/telescope/release/herdr-telescope" \
        "$plugins/telescope/bin/herdr-telescope"
    chmod 755 "$plugins/telescope/bin/herdr-telescope"

    git clone --depth 1 --branch v0.14.0 \
        https://github.com/fullerzz/herdr-plugin-sesh.git "$work/src/sesh"
    mash_copy_tree "$work/src/sesh" "$plugins/fullerzz.sesh"
    mkdir -p "$plugins/fullerzz.sesh/bin"
    ( cd "$plugins/fullerzz.sesh" && mash_go "$plugins/fullerzz.sesh" \
        -ldflags="-X=github.com/fullerzz/herdr-plugin-sesh/internal/app.Version=0.14.0" \
        -o bin/herdr-sesh ./cmd/herdr-sesh )

    git clone --depth 1 --branch v0.9.1 \
        https://github.com/kryptamine/herdr-auto-title.git "$work/src/auto-title"
    mash_copy_tree "$work/src/auto-title" "$plugins/herdr.auto-title"
    ( cd "$plugins/herdr.auto-title" && mash_go "$plugins/herdr.auto-title" \
        -o herdr-auto-title ./cmd/herdr-auto-title )

    git clone --depth 1 --branch v0.39.0 \
        https://github.com/persiyanov/herdr-reviewr.git "$work/src/reviewr"
    mash_copy_tree "$work/src/reviewr" "$plugins/persiyanov.reviewr"
    mash_cargo "$plugins/persiyanov.reviewr/Cargo.toml" reviewr
    mkdir -p "$plugins/persiyanov.reviewr/bin"
    cp "$root/dist/.cargo-target/reviewr/release/herdr-reviewr" \
        "$plugins/persiyanov.reviewr/bin/herdr-reviewr"
    chmod 755 "$plugins/persiyanov.reviewr/bin/herdr-reviewr"

    git clone --depth 1 --branch v0.5.0 \
        https://github.com/speardragon/herdr-plugin-manager.git "$work/src/plugin-manager"
    mash_copy_tree "$work/src/plugin-manager" "$plugins/ray.plugin-manager"

    git clone --depth 1 https://github.com/dot/herdr-terminal-notifier.git "$work/src/notifier"
    mash_copy_tree "$work/src/notifier" "$plugins/dot.terminal-notifier"
    local plist="$plugins/dot.terminal-notifier/assets/HerdrNotify.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.mash.notify' "$plist"
    codesign --force --deep --sign - "$plugins/dot.terminal-notifier/assets/HerdrNotify.app"

    git clone --depth 1 https://github.com/plannotator/herdr-annotate.git "$work/src/annotate"
    ( cd "$work/src/annotate" && bash scripts/fetch-herdr-annotate.sh )
    mash_copy_tree "$work/src/annotate" "$plugins/annotate"
}

mash_install_fonts() {
    local fonts="$app/Contents/Resources/Ghostty.app/Contents/Resources/Fonts"
    local font
    mkdir -p "$fonts"
    for font in \
        "MesloLGS NF Regular.ttf" \
        "MesloLGS NF Bold.ttf" \
        "MesloLGS NF Italic.ttf" \
        "MesloLGS NF Bold Italic.ttf"
    do
        cp "$root/packaging/fonts/$font" "$fonts/$font"
    done
    cp "$root/packaging/fonts/NOTICE.txt" "$fonts/NOTICE.txt"
    local plist="$app/Contents/Resources/Ghostty.app/Contents/Info.plist"
    if /usr/libexec/PlistBuddy -c 'Set :ATSApplicationFontsPath Fonts' "$plist" 2>/dev/null; then
        :
    else
        /usr/libexec/PlistBuddy -c 'Add :ATSApplicationFontsPath string Fonts' "$plist"
    fi
}

mash_wrap_gh() {
    local bin="$app/Contents/Resources/bin"
    [ -f "$bin/gh" ] || return 0
    mv "$bin/gh" "$bin/gh.bin"
    cat >"$bin/gh" <<'EOF'
#!/bin/bash
# Keep the GitHub token in Mash's gh directory. Do not write the login keychain.
real="$(cd "$(dirname "$0")" && pwd)/gh.bin"
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "login" ]; then
    shift 2
    exec "$real" auth login --insecure-storage "$@"
fi
exec "$real" "$@"
EOF
    chmod 755 "$bin/gh"
}

mash_link_plugins() {
    local dest="$1"
    local home="$2"
    local xdg="$dest/Contents/Resources/defaults"
    local sock="$dest/Contents/Resources/.plugin-link"
    local dir
    mkdir -p "$sock/state" "$sock/data" "$sock/cache"
    for dir in "$dest/Contents/Resources/plugins"/*; do
        if [ -f "$dir/lite/herdr-plugin.toml" ]; then
            dir="$dir/lite"
        fi
        [ -f "$dir/herdr-plugin.toml" ] || continue
        env -u HERDR_CONFIG_PATH -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH \
            HOME="$home" \
            XDG_CONFIG_HOME="$xdg" \
            XDG_STATE_HOME="$sock/state" \
            XDG_DATA_HOME="$sock/data" \
            XDG_CACHE_HOME="$sock/cache" \
            HERDR_CONFIG_PATH="$xdg/herdr/config.toml" \
            HERDR_SOCKET_PATH="$sock/herdr.sock" \
            HERDR_CLIENT_SOCKET_PATH="$sock/herdr-client.sock" \
            "$dest/Contents/Resources/bin/herdr" plugin link "$dir"
    done
    rm -rf "$sock"
    local listed="$xdg/herdr/plugins.json"
    [ -f "$listed" ] || { echo "plugins.json was not written into the bundle." >&2; exit 1; }
    grep -q "$dest/Contents/Resources/plugins" "$listed" || {
        echo "plugins.json does not point inside the bundle." >&2
        exit 1
    }
    if grep -q "$home/dotfiles/plugins" "$listed"; then
        echo "plugins.json points at the personal plugin tree." >&2
        exit 1
    fi
}

# Stop before packaging/build.sh replaces dist/Mash.app when the checkout is
# missing or is not the pinned release. Does not read or write personal trees.
mash_require_skills() {
    local src ver
    src="$home/Development/mash-programming-skills"
    if [ ! -f "$src/VERSION" ]; then
        echo "Mash Programming Skills checkout is missing. Leaving dist/Mash.app in place." >&2
        exit 1
    fi
    ver="$(tr -d '[:space:]' <"$src/VERSION")"
    if [ "$ver" != "0.5.14" ]; then
        echo "Mash Programming Skills VERSION is $ver, want 0.5.14. Leaving dist/Mash.app in place." >&2
        exit 1
    fi
}

mash_skills_src() {
    printf '%s\n' "$home/Development/mash-programming-skills"
}

# Copy the pinned checkout into the staged app. The checkout itself is not edited.
mash_install_skills() {
    local src pi cfg name destskill
    mash_require_skills
    src="$(mash_skills_src)"
    pi="$app/Contents/Resources/defaults/pi"
    cfg="$app/Contents/Resources/defaults/mash-config"
    case "$pi" in
        "$app/Contents/Resources/defaults/pi") ;;
        *) echo "refusing to install skills outside the staged app" >&2; exit 1 ;;
    esac
    mkdir -p "$pi/skills" "$pi/agents" "$pi/extensions" "$pi/scripts" \
        "$cfg/references/model-tiers" "$cfg/references/scoping-synthesis"
    for name in "$src/src/skills"/*; do
        [ -d "$name" ] || continue
        destskill="$pi/skills/$(basename "$name")"
        rm -rf "$destskill"
        mkdir -p "$destskill"
        tar -C "$name" \
            --exclude '.venv' \
            --exclude '__pycache__' \
            --exclude '.pytest_cache' \
            --exclude '.git' \
            --exclude 'node_modules' \
            -cf - . | tar -C "$destskill" -xf -
        find "$destskill" \( -name __pycache__ -o -name .pytest_cache -o -name .git -o -name .venv -o -name node_modules \) \
            -prune -exec rm -rf {} + 2>/dev/null || true
    done
    rm -rf "$pi/agents"
    mkdir -p "$pi/agents"
    tar -C "$src/src/agents" --exclude '.git' -cf - . | tar -C "$pi/agents" -xf -
    cp "$src/references/model-tiers/model-tiers.md" "$cfg/references/model-tiers/model-tiers.md"
    cp "$src/references/scoping-synthesis/scoping-synthesis.md" "$cfg/references/scoping-synthesis/scoping-synthesis.md"
    cp "$src/references/markdown-rendering.md" "$cfg/references/markdown-rendering.md"
    mash_write_pi_guidance "$pi/AGENTS.md"
    mash_write_append_system "$src" "$pi/APPEND_SYSTEM.md"
    mash_rewrite_skill_paths "$pi" "$cfg/references"
    mash_write_hindsight_extension "$pi"
    printf '0.8.3\n' >"$cfg/hindsight-pin"
    mash_build_parallel_venv "$cfg/venvs/mash-parallel"
    [ -f "$pi/skills/mash-plan/SKILL.md" ] || { echo "mash-plan was not staged" >&2; exit 1; }
    [ -d "$pi/agents" ] || { echo "agents were not staged" >&2; exit 1; }
    [ -f "$pi/APPEND_SYSTEM.md" ] || { echo "APPEND_SYSTEM.md was not staged" >&2; exit 1; }
    grep -q '"context7"' "$pi/mcp.json" || { echo "mcp.json is missing context7" >&2; exit 1; }
    if grep -q 'github' "$pi/mcp.json"; then
        echo "mcp.json must not carry a GitHub token" >&2
        exit 1
    fi
    if grep -q 'hindsight-embed' "$pi/scripts/ensure-hindsight-daemon.sh"; then
        echo "Hindsight warm-start must not call hindsight-embed" >&2
        exit 1
    fi
}

mash_write_pi_guidance() {
    cat >"$1" <<'EOF'
# Mash Programming Skills Agent Guidance

This file contains universal Mash Programming Skills workflow guidance only. It does not replace project-specific instructions in a repository's own AGENTS.md.

## Pi surfaces

- Always-on rules: `~/.mash/.pi/agent/APPEND_SYSTEM.md`
- Skills: `~/.mash/.pi/agent/skills/`
- Specialist agents: `~/.mash/.pi/agent/agents/`
- Shared references: `~/.mash/.config/mash/references/`
- Hindsight pin: `~/.mash/.config/mash/hindsight-pin`

Before non-trivial planning, implementation, or review work, follow the always-on Mash Programming Skills rules and use the relevant skill.

## Hindsight

Hindsight is optional. The session warm-start does not start a daemon. If the daemon is unavailable, continue and record `Hindsight: unavailable`.

## Repository ownership

Mash Programming Skills never writes a repository's `AGENTS.md`, `DESIGN.md`, or `.mash/*` working directories while being installed into Mash. Skills create their own working directories lazily when invoked.
EOF
}

mash_write_append_system() {
    local src="$1" dest="$2" mdc name description
    {
        echo "# Mash Programming Skills — always-on rules"
        echo
        echo "Auto-generated from src/rules/*.mdc with alwaysApply: true."
        echo "Shipped with Mash. Do not edit by hand."
    } >"$dest"
    for mdc in "$src"/src/rules/*.mdc; do
        [ -f "$mdc" ] || continue
        grep -qE '^alwaysApply:[[:space:]]*true' "$mdc" || continue
        name="$(basename "$mdc" .mdc)"
        description="$(awk '
            NR == 1 && /^---$/ { frontmatter = 1; next }
            frontmatter && /^---$/ { exit }
            frontmatter && /^description:[[:space:]]*/ {
                sub(/^description:[[:space:]]*/, "")
                if ($0 ~ /^".*"$/) {
                    sub(/^"/, "")
                    sub(/"$/, "")
                }
                print
                exit
            }
        ' "$mdc")"
        [ -n "$description" ] || description="$name"
        {
            echo
            echo "---"
            echo
            echo "## $description"
            echo
            awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$mdc"
        } >>"$dest"
    done
}

# On the staged copy only. Longer prefixes are replaced first so a Mash path is not rewritten twice.
mash_rewrite_skill_paths() {
    local py="$app/Contents/Resources/python/bin/python3"
    "$py" - "$@" <<'PY'
import os, sys
repls = (
    (b"~/.config/mash", b"~/.mash/.config/mash"),
    (b"~/.pi/agent", b"~/.mash/.pi/agent"),
    (b"~/.hindsight", b"~/.mash/.hindsight"),
)
skip = {"venvs", "__pycache__", ".pytest_cache", ".git", "node_modules", ".venv"}
for root in sys.argv[1:]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if b"\0" in data:
                continue
            updated = data
            for old, new in repls:
                updated = updated.replace(old, new)
            if updated != data:
                with open(path, "wb") as fh:
                    fh.write(updated)
PY
}

mash_write_hindsight_extension() {
    local pi="$1"
    mkdir -p "$pi/extensions" "$pi/scripts"
    cat >"$pi/extensions/mash-hindsight-daemon.ts" <<'EOF'
/**
 * Mash Programming Skills Hindsight warm-start for Pi.
 * Starts the script in PI_CODING_AGENT_DIR. That script does not start a daemon.
 */
import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const dir = process.env.PI_CODING_AGENT_DIR;
    if (!dir) return;
    const script = `${dir}/scripts/ensure-hindsight-daemon.sh`;
    try {
      const child = spawn(script, [], {
        detached: true,
        stdio: "ignore",
        env: process.env,
      });
      child.unref();
    } catch {
      // fail open — Hindsight is optional
    }
  });
}
EOF
    cat >"$pi/scripts/ensure-hindsight-daemon.sh" <<'EOF'
#!/bin/bash
# The Hindsight embed CLI stores profiles in the real home and has no directory switch.
# This script does not start it. Pi continues without a daemon.
exit 0
EOF
    chmod 755 "$pi/scripts/ensure-hindsight-daemon.sh"
    cat >"$pi/mcp.json" <<'EOF'
{
  "mcpServers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    },
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "-y",
        "chrome-devtools-mcp@1.10.1",
        "--categoryInput=false",
        "--categoryEmulation=false",
        "--categoryNetwork=false",
        "--categoryPerformance=false",
        "--memoryDebugging=true",
        "--isolated=true"
      ]
    }
  }
}
EOF
}

mash_build_parallel_venv() {
    local dest="$1"
    local py="$app/Contents/Resources/python/bin/python3"
    local req cache home_dir cleanup=""
    req="$(mash_skills_src)/src/skills/mash-parallel/requirements.txt"
    [ -f "$req" ] || { echo "missing mash-parallel requirements.txt" >&2; exit 1; }
    if [ -n "${work:-}" ] && [ -d "$work/pip-cache" ]; then
        cache="$work/pip-cache"
        home_dir="$work/home"
    else
        cache="$(mktemp -d "$root/dist/.skill-pip.XXXXXX")"
        home_dir="$cache/home"
        mkdir -p "$home_dir"
        cleanup="$cache"
    fi
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    env HOME="$home_dir" PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CACHE_DIR="$cache" \
        "$py" -m venv "$dest"
    env HOME="$home_dir" PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CACHE_DIR="$cache" \
        "$dest/bin/python" -m pip install -r "$req"
    [ -n "$cleanup" ] && rm -rf "$cleanup"
    "$dest/bin/python" -c 'import pytest'
}

# After the staged app moves, point the venv at the finished bundle path.
mash_finish_skill_venv() {
    local dest="$1"
    local old="${2:-}"
    local venv="$dest/Contents/Resources/defaults/mash-config/venvs/mash-parallel"
    local py="$dest/Contents/Resources/python/bin/python3"
    [ -d "$venv" ] || return 0
    [ -x "$py" ] || { echo "bundled Python is missing" >&2; exit 1; }
    if [ -n "$old" ] && [ "$old" != "$dest" ]; then
        "$py" - "$venv" "$old" "$dest" <<'PY'
import os, sys
venv, old, new = sys.argv[1:]
old_b, new_b = old.encode(), new.encode()
for dirpath, dirnames, filenames in os.walk(venv):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as fh:
            data = fh.read()
        if b"\0" in data or old_b not in data:
            continue
        with open(path, "wb") as fh:
            fh.write(data.replace(old_b, new_b))
PY
    fi
    ln -sfn "$py" "$venv/bin/python"
    ln -sfn python "$venv/bin/python3"
    if [ -L "$venv/bin/python3.13" ]; then
        ln -sfn python "$venv/bin/python3.13"
    fi
    "$venv/bin/python" -c 'import pytest'
}

mash_write_pins() {
    if [ ! -f "$root/packaging/pins.txt" ]; then
        mash_pins_text >"$root/packaging/pins.txt"
    fi
}
