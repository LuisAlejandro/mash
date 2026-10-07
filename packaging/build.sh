#!/bin/bash
# Assemble dist/Mash.app. Downloads programs into dist/.build.
# Custom plugins, helpers, and fonts come from this repo.
# Writes only under this repo's dist/. Does not start Herdr.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=carry.sh
source "$root/packaging/carry.sh"
dest="$root/dist/Mash.app"
work="$root/dist/.build"
app="$work/Mash.app"

case "$dest" in
    "$root/dist/Mash.app") ;;
    *) echo "refusing to build outside $root/dist" >&2; exit 1 ;;
esac

home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
[ "$(uname -m)" = "arm64" ] || { echo "Mash builds for arm64 only." >&2; exit 1; }

ship_helpers=(
    herdr-new-plain-tab
    herdr-new-dev-tab
    herdr-new-pi-tab
    herdr-new-reviewr-tab
    herdr-fresh-pane
    herdr-agent-name
    telescope-files
    telescope-sessions
    git-status-watch
    pr-watch-repo
    herdr-shell-greeting
    herdr-dev-tab-fill
    herdr-orchestration
)

for name in "${ship_helpers[@]}"; do
    [ -f "$root/packaging/helpers/$name" ] || {
        echo "missing packaged helper $name" >&2
        exit 1
    }
done
for cmd in curl tar unzip hdiutil shasum install_name_tool codesign ditto file patch; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing $cmd" >&2; exit 1; }
done
mash_require_sources
mash_require_skills
mash_pins_check
if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
    echo "Mash.app is running from $dest; leaving it in place." >&2
    exit 1
fi

rm -rf "$work"
mkdir -p "$work/home" "$work/npm-cache" "$work/pip-cache"

fetch() {
    local url="$1" out="$2" sha="$3"
    curl -fL --retry 2 --max-time 300 -o "$out" "$url"
    echo "$sha  $out" | shasum -a 256 -c -
}

fetch_bottle() {
    local name="$1" url="$2" sha="$3"
    mkdir -p "$work/cellar/$name"
    curl -fL --retry 2 --max-time 300 \
        -H "Authorization: Bearer QQ==" \
        -H "Accept: application/vnd.oci.image.layer.v1.tar+gzip" \
        -o "$work/cellar/$name.tar.gz" "$url"
    echo "$sha  $work/cellar/$name.tar.gz" | shasum -a 256 -c -
    tar -xzf "$work/cellar/$name.tar.gz" -C "$work/cellar/$name"
}

bottle_bin() {
    local hit
    hit="$(find "$work/cellar/$1" -type f -path "*/bin/$2" -print -quit)"
    [ -n "$hit" ] || { echo "bottle $1 has no bin/$2" >&2; exit 1; }
    printf '%s\n' "$hit"
}

take_bin() {
    mkdir -p "$work/tools"
    cp -L "$2" "$work/tools/$1"
    chmod 755 "$work/tools/$1"
}

unpack_bin() {
    local name="$1" url="$2" sha="$3" member="${4:-}" dir
    dir="$work/unpack/$name"
    mkdir -p "$dir"
    fetch "$url" "$dir/archive" "$sha"
    case "$url" in
        *.tar.gz)
            tar -xzf "$dir/archive" -C "$dir"
            take_bin "$name" "$dir/$member"
            ;;
        *.zip)
            unzip -q "$dir/archive" -d "$dir"
            take_bin "$name" "$dir/$member"
            ;;
        *.gz)
            gunzip -c "$dir/archive" >"$dir/$name"
            chmod 755 "$dir/$name"
            take_bin "$name" "$dir/$name"
            ;;
        *)
            cp "$dir/archive" "$dir/$name"
            chmod 755 "$dir/$name"
            take_bin "$name" "$dir/$name"
            ;;
    esac
}

fetch "https://nodejs.org/dist/v24.16.0/node-v24.16.0-darwin-arm64.tar.gz" \
    "$work/node.tar.gz" \
    "39189dab4eeb15706c424af0ac08a3044c9e48f7db12a7d77f6b7aafc7dd5df6"
tar -xzf "$work/node.tar.gz" -C "$work"

fetch "https://github.com/astral-sh/python-build-standalone/releases/download/20261003/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only.tar.gz" \
    "$work/python.tar.gz" \
    "d8975d7df4f08f7b1c7aafcdfacbddcec3d366415f2c1a72b2466b6850815933"
tar -xzf "$work/python.tar.gz" -C "$work"

# Bottles still say @@HOMEBREW_PREFIX@@. embed_deps rewrites those to the
# copies under Contents/Resources/lib. Nothing is read from /opt/homebrew.
fetch_bottle herdr \
    "https://ghcr.io/v2/homebrew/core/herdr/blobs/sha256:d381e8af36dc499593101d33b80098dd7316ba9f167b1535e4eeb76b2ac2e58a" \
    "d381e8af36dc499593101d33b80098dd7316ba9f167b1535e4eeb76b2ac2e58a"
fetch_bottle eza \
    "https://ghcr.io/v2/homebrew/core/eza/blobs/sha256:94b3b640649a5e89a6f75c15fa2fa66098cf78c4faf742a6d43771fe377f31a0" \
    "94b3b640649a5e89a6f75c15fa2fa66098cf78c4faf742a6d43771fe377f31a0"
fetch_bottle gopls \
    "https://ghcr.io/v2/homebrew/core/gopls/blobs/sha256:a4506e1cce44eb5d2497c7f8a7bfe519201160990fb8198d69592bb8d3328994" \
    "a4506e1cce44eb5d2497c7f8a7bfe519201160990fb8198d69592bb8d3328994"
fetch_bottle git \
    "https://ghcr.io/v2/homebrew/core/git/blobs/sha256:db3fbed936fd0a1dbdc265e1be33bfe6584a98d692aab9c21c10f1890fd3b78b" \
    "db3fbed936fd0a1dbdc265e1be33bfe6584a98d692aab9c21c10f1890fd3b78b"
fetch_bottle pcre2 \
    "https://ghcr.io/v2/homebrew/core/pcre2/blobs/sha256:0ec47d18c50f5770db2b3f07b5b85644284cc6ee8e07e23b11d2727e95932b77" \
    "0ec47d18c50f5770db2b3f07b5b85644284cc6ee8e07e23b11d2727e95932b77"
fetch_bottle gettext \
    "https://ghcr.io/v2/homebrew/core/gettext/blobs/sha256:98a116d35792ccd730360ffc8c0d8fc5799b2282b96bb7696192c573f064a331" \
    "98a116d35792ccd730360ffc8c0d8fc5799b2282b96bb7696192c573f064a331"
fetch_bottle libgit2 \
    "https://ghcr.io/v2/homebrew/core/libgit2/blobs/sha256:68a1ad4fce40bdf9e0c260255673ad0922fa907e6694640fadd13390175b2ba7" \
    "68a1ad4fce40bdf9e0c260255673ad0922fa907e6694640fadd13390175b2ba7"
fetch_bottle llhttp \
    "https://ghcr.io/v2/homebrew/core/llhttp/blobs/sha256:0a3866a86832c768383c04809baccccfa1293a520d3d13654d7c051f12c02c80" \
    "0a3866a86832c768383c04809baccccfa1293a520d3d13654d7c051f12c02c80"
fetch_bottle libssh2 \
    "https://ghcr.io/v2/homebrew/core/libssh2/blobs/sha256:916856f463c8b6f29d5a36c5b6f0ab6f62f5c4c3098dcd0b111028fb311a69c7" \
    "916856f463c8b6f29d5a36c5b6f0ab6f62f5c4c3098dcd0b111028fb311a69c7"
fetch_bottle openssl \
    "https://ghcr.io/v2/homebrew/core/openssl/3/blobs/sha256:a1ef3283ad41feaedac5d41dafc4c2a71db6492c3a45a4d1755cfb19d02afc7b" \
    "a1ef3283ad41feaedac5d41dafc4c2a71db6492c3a45a4d1755cfb19d02afc7b"
take_bin herdr "$(bottle_bin herdr herdr)"
take_bin eza "$(bottle_bin eza eza)"
take_bin gopls "$(bottle_bin gopls gopls)"
take_bin git "$(bottle_bin git git)"
git_bin="$work/tools/git"

unpack_bin lazygit \
    "https://github.com/jesseduffield/lazygit/releases/download/v0.65.1/lazygit_0.65.1_darwin_arm64.tar.gz" \
    "65a367c6ea9a88efebaaf7998a6835eedb987e04916cef677264ff9b31b1b13e" \
    "lazygit"
unpack_bin lazydocker \
    "https://github.com/jesseduffield/lazydocker/releases/download/v0.25.2/lazydocker_0.25.2_Darwin_arm64.tar.gz" \
    "4a54d7b4abdf255b2bce9806641eac5568d5b7fbc820c1b5d3f9e34ea1367d60" \
    "lazydocker"
unpack_bin pet \
    "https://github.com/knqyf263/pet/releases/download/v1.0.1/pet_1.0.1_darwin_arm64.tar.gz" \
    "f3ba11bc1cb2b2edc8725648e52d871e417eaa76d8b1c12fa8e24e4f1c704f03" \
    "pet"
unpack_bin zoxide \
    "https://github.com/ajeetdsouza/zoxide/releases/download/v0.10.0/zoxide-0.10.0-aarch64-apple-darwin.tar.gz" \
    "b55ae6f2f5f23d0a6ccb3bd4eeb2af9c7e0a6556e5255c82100e40305129bbb0" \
    "zoxide"
unpack_bin fzf \
    "https://github.com/junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-darwin_arm64.tar.gz" \
    "b7f34c964d8e52c471c933cef8ec43dc71997c266cafafd1b013bed10fc229a1" \
    "fzf"
unpack_bin fd \
    "https://github.com/sharkdp/fd/releases/download/v10.5.0/fd-v10.5.0-aarch64-apple-darwin.tar.gz" \
    "b67e1836c468e42e411984b56e52fa7abec08c2bd22c867398e7cc134aac5e12" \
    "fd-v10.5.0-aarch64-apple-darwin/fd"
unpack_bin bat \
    "https://github.com/sharkdp/bat/releases/download/v0.26.1/bat-v0.26.1-aarch64-apple-darwin.tar.gz" \
    "e30beff26779c9bf60bb541e1d79046250cb74378f2757f8eb250afddb19e114" \
    "bat-v0.26.1-aarch64-apple-darwin/bat"
unpack_bin rg \
    "https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-aarch64-apple-darwin.tar.gz" \
    "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4" \
    "ripgrep-15.2.0-aarch64-apple-darwin/rg"
unpack_bin delta \
    "https://github.com/dandavison/delta/releases/download/0.19.2/delta-0.19.2-aarch64-apple-darwin.tar.gz" \
    "9be36612a5a13e9e386dc498fb8e50dc87c72ee42b63db0ea05b32f99a72a69a" \
    "delta-0.19.2-aarch64-apple-darwin/delta"
unpack_bin atuin \
    "https://github.com/atuinsh/atuin/releases/download/v18.23.0/atuin-aarch64-apple-darwin.tar.gz" \
    "c988be1cde19cd7295ce64bc8b955d42fb1855e5227cb640c87fc09c8408c3fc" \
    "atuin-aarch64-apple-darwin/atuin"
unpack_bin texlab \
    "https://github.com/latex-lsp/texlab/releases/download/v5.26.0/texlab-aarch64-macos.tar.gz" \
    "af7972ffd230711ba04ada9b69cc32ce9111d9196ba69538062872faefdbee56" \
    "texlab"
unpack_bin gh \
    "https://github.com/cli/cli/releases/download/v2.95.0/gh_2.95.0_macOS_arm64.zip" \
    "3677f9c27965825f9c7d50395473c134edaea4b484373ef6b25de653570a0489" \
    "gh_2.95.0_macOS_arm64/bin/gh"
unpack_bin jq \
    "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-macos-arm64" \
    "a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603"
unpack_bin shfmt \
    "https://github.com/mvdan/sh/releases/download/v3.14.1/shfmt_v3.14.1_darwin_arm64" \
    "b7c872db63553ccffc7253aba3ed7d4885a27d83f1ba567b1138c6315a5847e5"
# Release tag 2026-09-28. The binary reports 2026-09-27, which is the pin.
unpack_bin rust-analyzer \
    "https://github.com/rust-lang/rust-analyzer/releases/download/2026-09-28/rust-analyzer-aarch64-apple-darwin.gz" \
    "54ec873d8996e2c127d758bf45d4eacb6d3371dae4f6f6d5d3f05cedbae5fd59"

fetch "https://release.files.ghostty.org/1.3.1/Ghostty.dmg" \
    "$work/Ghostty.dmg" \
    "18cff2b0a6cee90eead9c7d3064e808a252a40baf214aa752c1ecb793b8f5f69"
mkdir -p "$work/ghostty-mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$work/ghostty-mnt" "$work/Ghostty.dmg"
ditto "$work/ghostty-mnt/Ghostty.app" "$work/Ghostty.app" || {
    hdiutil detach "$work/ghostty-mnt" || true
    exit 1
}
hdiutil detach "$work/ghostty-mnt"
ghostty_src="$work/Ghostty.app"
orig="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ghostty_src/Contents/Info.plist")"
[ "$orig" = "com.mitchellh.ghostty" ] || {
    echo "downloaded Ghostty bundle id is $orig" >&2
    exit 1
}

fetch "https://static.rust-lang.org/dist/rust-1.98.1-aarch64-apple-darwin.tar.gz" \
    "$work/rust.tar.gz" \
    "cfc171d8120d401b10a1028c52646dd8e00e3e66852f949061ce087845f55afd"
tar -xzf "$work/rust.tar.gz" -C "$work"
"$work/rust-1.98.1-aarch64-apple-darwin/install.sh" \
    --prefix="$work/rustc" --without=rust-docs
fetch "https://go.dev/dl/go1.26.4.darwin-arm64.tar.gz" \
    "$work/go.tar.gz" \
    "b62ad2b6d7d2464f12a5bcad7ff47f19d08325773b5efd21610e445a05a9bf53"
tar -xzf "$work/go.tar.gz" -C "$work"

tools=(
    "herdr:$work/tools/herdr"
    "lazygit:$work/tools/lazygit"
    "lazydocker:$work/tools/lazydocker"
    "pet:$work/tools/pet"
    "zoxide:$work/tools/zoxide"
    "eza:$work/tools/eza"
    "fzf:$work/tools/fzf"
    "fd:$work/tools/fd"
    "shfmt:$work/tools/shfmt"
    "bat:$work/tools/bat"
    "rg:$work/tools/rg"
    "jq:$work/tools/jq"
    "gh:$work/tools/gh"
    "delta:$work/tools/delta"
    "gopls:$work/tools/gopls"
    "rust-analyzer:$work/tools/rust-analyzer"
    "texlab:$work/tools/texlab"
    "atuin:$work/tools/atuin"
)

# Homebrew marksman is a script that launches Homebrew's .NET. Ship the
# upstream binary instead. It links only system libraries.
fetch "https://github.com/artempyanykh/marksman/releases/download/2026-02-08/marksman-macos" \
    "$work/marksman-macos" \
    "6a801c17b5ac0dba69787c5282b3b3bd416e66c96253fae098d311c6bbd1833b"
chmod 755 "$work/marksman-macos"

if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
    echo "Mash.app is running from $dest; leaving it in place." >&2
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/lib" \
    "$app/Contents/Resources/node"
cp -R "$work/node-v24.16.0-darwin-arm64/bin" "$work/node-v24.16.0-darwin-arm64/lib" \
    "$app/Contents/Resources/node/"
[ -d "$work/python/bin" ] || { echo "python archive has no bin/" >&2; exit 1; }
cp -R "$work/python" "$app/Contents/Resources/python"

env HOME="$work/home" \
    npm_config_cache="$work/npm-cache" \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    npm_config_audit=false \
    "$app/Contents/Resources/node/bin/npm" install --global \
    --prefix "$app/Contents/Resources/node" \
    @earendil-works/pi-coding-agent@0.99.1 \
    bash-language-server@5.8.1 \
    typescript-language-server@6.0.1 \
    yaml-language-server@1.24.0 \
    svelte-language-server@0.18.4 \
    vscode-langservers-extracted@4.10.0 \
    @tailwindcss/language-server@0.16.0 \
    pi-subagents@0.76.0 \
    pi-mcp-adapter@5.0.0 \
    pi-ask-user@0.16.0 \
    @krfantasy/pi-monokai-pro@0.2.0 \
    pi-plan-mode@0.4.8 \
    pi-web-search@1.6.0 \
    prettier@3.9.9 \
    prettier-plugin-svelte@4.1.1

node_real="$app/Contents/Resources/node/bin/node"
while IFS= read -r script; do
    case "$(head -n 1 "$script")" in
        "#!$node_real"*)
            { echo '#!/usr/bin/env node'; tail -n +2 "$script"; } >"$script.mashshebang"
            mv "$script.mashshebang" "$script"
            chmod 755 "$script"
            ;;
    esac
done < <(find "$app/Contents/Resources/node" -type f)

env HOME="$work/home" \
    PIP_CACHE_DIR="$work/pip-cache" \
    PYTHONNOUSERSITE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$app/Contents/Resources/python/bin/python3" -m pip install 'python-lsp-server==1.15.0'

cat >"$app/Contents/Resources/bin/node" <<'EOF'
#!/bin/bash
exec "$(cd "$(dirname "$0")/../node/bin" && pwd)/node" "$@"
EOF
cat >"$app/Contents/Resources/bin/npm" <<'EOF'
#!/bin/bash
exec "$(cd "$(dirname "$0")/../node/bin" && pwd)/npm" "$@"
EOF
cat >"$app/Contents/Resources/bin/python3" <<'EOF'
#!/bin/bash
export PYTHONNOUSERSITE=1
exec "$(cd "$(dirname "$0")/../python/bin" && pwd)/python3" "$@"
EOF
cat >"$app/Contents/Resources/bin/pylsp" <<'EOF'
#!/bin/bash
export PYTHONNOUSERSITE=1
exec "$(cd "$(dirname "$0")/../python/bin" && pwd)/python3" -m pylsp "$@"
EOF
cat >"$app/Contents/Resources/bin/prettier" <<'EOF'
#!/bin/bash
# Load the bundled Svelte plugin. Fresh calls prettier by name.
root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/node/bin/node" "$root/node/lib/node_modules/prettier/bin/prettier.cjs" \
    --plugin "$root/node/lib/node_modules/prettier-plugin-svelte/plugin.js" \
    "$@"
EOF
chmod 755 "$app/Contents/Resources/bin/node" "$app/Contents/Resources/bin/npm" \
    "$app/Contents/Resources/bin/python3" "$app/Contents/Resources/bin/pylsp" \
    "$app/Contents/Resources/bin/prettier"

lib="$app/Contents/Resources/lib"
cellar_dep() {
    local base="$1" hit
    hit="$(find "$work/cellar" \( -type f -o -type l \) -name "$base" -print -quit)"
    [ -n "$hit" ] || { echo "missing library $base" >&2; exit 1; }
    printf '%s\n' "$hit"
}
embed_deps() {
    local file="$1" dep base target
    while IFS= read -r dep; do
        case "$dep" in
            /opt/homebrew/*|@@HOMEBREW_*) ;;
            *) continue ;;
        esac
        base="$(basename "$dep")"
        [ "$base" = "$(basename "$file")" ] && continue
        target="$lib/$base"
        if [ ! -f "$target" ]; then
            cp -L "$(cellar_dep "$base")" "$target"
            chmod u+w "$target"
            codesign --remove-signature "$target" 2>/dev/null || true
            install_name_tool -id "@loader_path/$base" "$target"
            embed_deps "$target"
        fi
        if [ "$(dirname "$file")" = "$lib" ]; then
            install_name_tool -change "$dep" "@loader_path/$base" "$file"
        else
            install_name_tool -change "$dep" "@rpath/$base" "$file"
        fi
    done < <(otool -L "$file" | awk 'NR>1 {print $1}')
}
embed_tool() {
    local name="$1" src="$2" out
    out="$app/Contents/Resources/bin/$name"
    cp -L "$src" "$out"
    chmod u+w "$out"
    if ! file "$out" | grep -q 'Mach-O'; then
        return 0
    fi
    codesign --remove-signature "$out" 2>/dev/null || true
    install_name_tool -add_rpath @executable_path/../lib "$out"
    embed_deps "$out"
}
for spec in "${tools[@]}"; do
    embed_tool "${spec%%:*}" "${spec#*:}"
done
mash_wrap_gh
embed_tool git "$git_bin"
embed_tool marksman "$work/marksman-macos"

for name in git eza bat rg jq delta; do
    if otool -L "$app/Contents/Resources/bin/$name" | awk 'NR>1 {print $1}' | grep -q -E '^/opt/homebrew/|^@@HOMEBREW_'; then
        echo "$name still links Homebrew." >&2
        exit 1
    fi
done

for name in "${ship_helpers[@]}"; do
    cp "$root/packaging/helpers/$name" "$app/Contents/Resources/bin/$name"
    chmod 755 "$app/Contents/Resources/bin/$name"
done
cp "$root/packaging/lib.sh" "$app/Contents/Resources/bin/lib.sh"
cp "$root/packaging/herdr-pane" "$app/Contents/Resources/bin/herdr-pane"
cp "$root/packaging/mash-shell" "$app/Contents/Resources/bin/mash-shell"
cp "$root/packaging/mash" "$app/Contents/MacOS/mash"
chmod 755 "$app/Contents/MacOS/mash" \
    "$app/Contents/Resources/bin/herdr-pane" \
    "$app/Contents/Resources/bin/mash-shell"
cp -R "$root/packaging/defaults" "$app/Contents/Resources/defaults"
cp "$root/packaging/uninstall" "$app/Contents/Resources/uninstall"
chmod 755 "$app/Contents/Resources/uninstall"
env HOME="$work/home" \
    npm_config_cache="$work/npm-cache" \
    npm_config_update_notifier=false \
    "$app/Contents/Resources/node/bin/npm" install --prefix "$app/Contents/Resources/defaults/pi" \
    pi-subagents@0.76.0 \
    pi-mcp-adapter@5.0.0 \
    pi-ask-user@0.16.0 \
    @krfantasy/pi-monokai-pro@0.2.0 \
    pi-plan-mode@0.4.8 \
    pi-web-search@1.6.0
mash_install_skills
# Sign git before the plugin clones use it. install_name_tool breaks its signature.
sign_downloaded() {
    local f
    for f in "$app/Contents/Resources/bin/git" "$app/Contents/Resources/lib"/*; do
        [ -f "$f" ] || continue
        if file "$f" | grep -q 'Mach-O'; then
            codesign --force --sign - "$f"
        fi
    done
}
sign_downloaded
export PATH="$work/rustc/bin:$work/go/bin:$app/Contents/Resources/bin:$PATH"
export GOTOOLCHAIN=local
mash_build_fresh
mash_build_plugins

ditto "$ghostty_src" "$app/Contents/Resources/Ghostty.app"
plist="$app/Contents/Resources/Ghostty.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.mash.ghostty' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Mash' "$plist"
if /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Mash' "$plist" 2>/dev/null; then
    :
else
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Mash' "$plist"
fi
mash_install_fonts

cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>mash</string>
	<key>CFBundleIdentifier</key>
	<string>app.mash</string>
	<key>CFBundleName</key>
	<string>Mash</string>
	<key>CFBundleDisplayName</key>
	<string>Mash</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

while IFS= read -r macho; do
    if file "$macho" | grep -q 'Mach-O'; then
        codesign --force --sign - "$macho"
    fi
done < <(find \
    "$app/Contents/Resources/bin" \
    "$app/Contents/Resources/lib" \
    "$app/Contents/Resources/libexec" \
    "$app/Contents/Resources/plugins" \
    -type f)
codesign --force --deep --sign - \
    "$app/Contents/Resources/plugins/dot.terminal-notifier/assets/HerdrNotify.app"

# Reject the OpenCode, Hindsight, and Rosey programs. pi ships provider
# modules whose filenames mention opencode; those are not the OpenCode app.
for banned in opencode hindsight rosey; do
    if find "$app/Contents/Resources/bin" -type f -iname "$banned" | grep -q .; then
        echo "bundle contains $banned" >&2
        exit 1
    fi
    if find "$app/Contents/Resources/node/bin" "$app/Contents/Resources/node/lib/node_modules" \
        -maxdepth 2 -type d -iname "$banned" 2>/dev/null | grep -q .; then
        echo "bundle contains $banned" >&2
        exit 1
    fi
done

copy="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
orig="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ghostty_src/Contents/Info.plist")"
[ "$orig" = "com.mitchellh.ghostty" ] || { echo "original Ghostty bundle id changed: $orig" >&2; exit 1; }
[ "$copy" = "app.mash.ghostty" ] || { echo "copy bundle id is $copy" >&2; exit 1; }
if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
    echo "Mash.app is running from $dest; leaving it in place." >&2
    exit 1
fi
rm -rf "$dest"
mv "$app" "$dest"
mash_finish_skill_venv "$dest" "$work/Mash.app"
mash_link_plugins "$dest" "$home"
codesign --force --deep --sign - "$dest/Contents/Resources/Ghostty.app"
codesign --force --sign - "$dest"
mash_write_pins
chmod -R u+w "$work" "$root/dist/.cargo" "$root/dist/.cargo-target" 2>/dev/null || true
rm -rf "$work" "$root/dist/.cargo" "$root/dist/.cargo-target"
echo "built $dest"
echo "downloaded Ghostty bundle id stayed $orig"
