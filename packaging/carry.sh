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
    for name in cache-hit dev-tab fingers fork-from-message pr-watch-focus herdr-workspace telescope; do
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
    for name in cache-hit dev-tab fingers fork-from-message pr-watch-focus; do
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

mash_write_pins() {
    if [ ! -f "$root/packaging/pins.txt" ]; then
        mash_pins_text >"$root/packaging/pins.txt"
    fi
}
