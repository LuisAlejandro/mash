#!/bin/bash
# Assemble dist/Mash.app. Downloads programs into dist/.build.
# Custom plugins, helpers, and fonts come from this repo.
# Writes only under this repo's dist/. Does not start Herdr.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# Folder name of the terminal bundle nested in Mash.app. macOS draws a Dock
# tile's label from the bundle's FOLDER NAME, not from CFBundleName or
# CFBundleDisplayName -- proved with a throwaway bundle named PlainBeta.app
# carrying CFBundleName "Alpha" and CFBundleDisplayName "Alpha Display",
# registered in /Applications, which still showed "PlainBeta" under the tile.
# So this literal, not the plist keys, is what the running tile says. One
# variable because build.sh and carry.sh build the same layout.
terminal_app="Mash Terminal.app"
# shellcheck source=carry.sh
source "$root/packaging/carry.sh"
# shellcheck source=build-common.sh
source "$root/packaging/build-common.sh"
dest="$root/dist/Mash.app"
work="$root/dist/.build"
app="$work/Mash.app"

# The resource root shared staging fills. macOS uses the app bundle's Resources;
# the Linux adapter uses the package's /opt/letsmash. See packaging/build-common.sh.
export MASH_RES_ROOT="$app/Contents/Resources"

case "$dest" in
"$root/dist/Mash.app") ;;
*)
  echo "refusing to build outside $root/dist" >&2
  exit 1
  ;;
esac

home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
[ "$(uname -m)" = "arm64" ] || {
  echo "Mash builds for arm64 only." >&2
  exit 1
}

ship_helpers=(
  mash-bin
  herdr-json
  herdr-agent-start
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
  herdr_state.py
  herdr-shell-greeting
  herdr-dev-tab-fill
  herdr-fresh-shell-pane
  herdr-annotate-paste
  mash-orchestration
  mash-hindsight-install
  hindsight-embed
  mash-voice-model
  mash-notify
  mash-seed-sync
  mash-update-notice
  mash-update-verify
  mash-update-apply
  mash-github-mcp
)

for name in "${ship_helpers[@]}"; do
  [ -f "$root/packaging/helpers/$name" ] || {
    echo "missing packaged helper $name" >&2
    exit 1
  }
done
for cmd in cargo git curl tar unzip hdiutil shasum install_name_tool codesign ditto file patch python3 xcodebuild xcrun; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing $cmd" >&2
    exit 1
  }
done
[ -f "$root/packaging/Mash.icns" ] || { echo "missing packaging/Mash.icns" >&2; exit 1; }
mash_require_sources
mash_require_skills
mash_pins_check
if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
  echo "Mash.app is running from $dest; leaving it in place." >&2
  exit 1
fi

# A failed run can leave the Go module cache read-only, which makes a plain rm
# fail and abort the next build before it starts.
chmod -R u+w "$work" 2>/dev/null || true
rm -rf "$work"
mkdir -p "$work/home" "$work/npm-cache" "$work/pip-cache"

# Branding is generated from header-art.ansi. Keep the committed preview and
# the .icns in lock-step with it, or a release could show one logo in Pi and a
# different one in Finder. Generate into the disposable work tree and compare;
# never rewrite tracked files as a side effect of building.
python3 "$root/branding/render_header_art.py" "$work/logo-solid.png" >/dev/null
cmp -s "$work/logo-solid.png" "$root/branding/logo-solid.png" || {
  echo "branding/logo-solid.png is stale; run branding/render_header_art.py" >&2
  exit 1
}
python3 "$root/branding/build_icns.py" "$work/Mash.icns" >/dev/null
cmp -s "$work/Mash.icns" "$root/packaging/Mash.icns" || {
  echo "packaging/Mash.icns is stale; run branding/build_icns.py" >&2
  exit 1
}
python3 "$root/branding/build_dmg_background.py" "$work/dmg-background.png" >/dev/null
cmp -s "$work/dmg-background.png" "$root/branding/dmg-background.png" || {
  echo "branding/dmg-background.png is stale; run branding/build_dmg_background.py" >&2
  exit 1
}
# The first-open wizard. Built here so the bundle never ships a stale binary.
wizard_bin="$root/dist/.cargo-target/wizard/release/mash-wizard"
mash_cargo "$root/packaging/wizard/Cargo.toml" wizard
[ -x "$wizard_bin" ] || {
  echo "wizard binary was not produced." >&2
  exit 1
}

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
  [ -n "$hit" ] || {
    echo "bottle $1 has no bin/$2" >&2
    exit 1
  }
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

# Herdr is Mash's core UI process. None of the opt-in host utilities are
# downloaded here; Git comes from the build machine for plugin source clones.
fetch_bottle herdr \
  "https://ghcr.io/v2/homebrew/core/herdr/blobs/sha256:d381e8af36dc499593101d33b80098dd7316ba9f167b1535e4eeb76b2ac2e58a" \
  "d381e8af36dc499593101d33b80098dd7316ba9f167b1535e4eeb76b2ac2e58a"
take_bin herdr "$(bottle_bin herdr herdr)"

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
unpack_bin atuin \
  "https://github.com/atuinsh/atuin/releases/download/v18.23.0/atuin-aarch64-apple-darwin.tar.gz" \
  "c988be1cde19cd7295ce64bc8b955d42fb1855e5227cb640c87fc09c8408c3fc" \
  "atuin-aarch64-apple-darwin/atuin"
unpack_bin starship \
  "https://github.com/starship/starship/releases/download/v1.27.0/starship-aarch64-apple-darwin.tar.gz" \
  "5362da8cb2928f98f3ce0ffda697cf0f8de70081db000dae316d6d3a404f6cf0" \
  "starship"

# zsh-autosuggestions is source, not an executable: keep its whole pinned tree
# beside the program directory so zsh can source it from the read-only bundle.
fetch "https://github.com/zsh-users/zsh-autosuggestions/archive/refs/tags/v0.7.1.tar.gz" \
  "$work/zsh-autosuggestions.tar.gz" \
  "0df7affff21cd87ed298e6a3970ed08a1dd66a6efa676454ee5b091ad503badf"
mkdir -p "$work/zsh-autosuggestions"
tar -xzf "$work/zsh-autosuggestions.tar.gz" -C "$work/zsh-autosuggestions"

# Host utilities (git, gh, fzf, fd, bat, rg, jq, delta, eza, zoxide) and
# Fresh's formatters and language servers are installed on the user's machine
# by mash-wizard. They are never copied into Mash.app.

# Ghostty is built from Mash's fork, not downloaded. Everything Mash wants to
# control about the terminal -- menu items, the About panel, behavior -- is
# hardcoded in upstream's Swift, out of reach of any bundle key, so it has to
# come from source. See mash_build_ghostty in carry.sh for the host
# requirements and why the Zig version is not free to drift.
# MASH_GHOSTTY_SRC wins over both host locations: CI clones the pinned fork
# into its own runner temp and exports it, and neither path below exists there.
# mash_build_ghostty already resolves it the same way, so the trim check must
# read the very tree that gets built rather than a developer-only checkout.
ghostty_fork="${MASH_GHOSTTY_SRC:-$home/Development/ghostty}"
[ -d "$ghostty_fork/.git" ] || ghostty_fork="/Volumes/Documents/Software/ghostty"
ghostty_zig_version="0.16.0"
ghostty_zig_url="https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz"
zig_bin="/Volumes/Documents/Software/tools/zig-$ghostty_zig_version/zig"
# Overridable because the identifier is Xcode-version-specific: CI reads it
# back from `xcodebuild -showComponent MetalToolchain` on its own runner rather
# than trusting this one.
ghostty_metal_toolchain="${MASH_METAL_TOOLCHAIN:-com.apple.dt.toolchain.Metal.32023.921.5}"
# Before building: fail if a rebase brought back a Ghostty feature Mash
# removes. See mash_ghostty_trim_check for why each check exists.
mash_ghostty_trim_check "$ghostty_fork" || {
  echo "the Ghostty fork no longer matches what Mash ships" >&2
  exit 1
}
mash_build_ghostty
ghostty_src="$work/Ghostty.app"
orig="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ghostty_src/Contents/Info.plist")"
[ "$orig" = "com.mitchellh.ghostty" ] || {
  echo "forked Ghostty bundle id is $orig" >&2
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
  "atuin:$work/tools/atuin"
  "starship:$work/tools/starship"
)

if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
  echo "Mash.app is running from $dest; leaving it in place." >&2
  exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/lib" \
  "$app/Contents/Resources/node"
cp -R "$work/node-v24.16.0-darwin-arm64/bin" "$work/node-v24.16.0-darwin-arm64/lib" \
  "$app/Contents/Resources/node/"
[ -d "$work/python/bin" ] || {
  echo "python archive has no bin/" >&2
  exit 1
}
cp -R "$work/python" "$app/Contents/Resources/python"

# Resolve the pins first: bash ignores the exit status of a failing command
# substitution inside an argument list, so a broken pin would otherwise install
# a shorter package set and still exit 0.
pi_packages="$(mash_pi_packages)" || {
  echo "could not resolve the pinned Pi packages" >&2
  exit 1
}
env HOME="$work/home" \
  npm_config_cache="$work/npm-cache" \
  npm_config_update_notifier=false \
  npm_config_fund=false \
  npm_config_audit=false \
  "$app/Contents/Resources/node/bin/npm" install --global \
  --prefix "$app/Contents/Resources/node" \
  $pi_packages
"$root/packaging/tests/test_pi_runtime.sh" "$app/Contents/Resources"

node_real="$app/Contents/Resources/node/bin/node"
while IFS= read -r script; do
  case "$(head -n 1 "$script")" in
  "#!$node_real"*)
    {
      echo '#!/usr/bin/env node'
      tail -n +2 "$script"
    } >"$script.mashshebang"
    mv "$script.mashshebang" "$script"
    chmod 755 "$script"
    ;;
  esac
done < <(find "$app/Contents/Resources/node" -type f)

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
# Interpreter choke point for everything on a pane's PATH. PYTHONDONTWRITEBYTECODE
# belongs here, not only in the launcher: the launcher's export covers the panes
# it starts, while this covers every other caller -- plugin startup processes,
# hourly helpers, anything a user types -- and Mash.app is signed, so a stray
# __pycache__ inside it breaks the seal.
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
exec "$(cd "$(dirname "$0")/../python/bin" && pwd)/python3" "$@"
EOF
chmod 755 "$app/Contents/Resources/bin/node" "$app/Contents/Resources/bin/npm" \
  "$app/Contents/Resources/bin/python3"

lib="$app/Contents/Resources/lib"
cellar_dep() {
  local base="$1" hit
  hit="$(find "$work/cellar" \( -type f -o -type l \) -name "$base" -print -quit)"
  [ -n "$hit" ] || {
    echo "missing library $base" >&2
    exit 1
  }
  printf '%s\n' "$hit"
}
embed_deps() {
  local file="$1" dep base target
  while IFS= read -r dep; do
    case "$dep" in
    /opt/homebrew/* | @@HOMEBREW_*) ;;
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
  embed_deps "$out"
  # Only add the rpath when the binary actually resolves a dylib through it.
  # Static Go binaries (fzf) and single-file tools have no @rpath load
  # commands; install_name_tool refuses to touch some of them, so skip.
  if otool -L "$out" | awk 'NR>1 {print $1}' | grep -q '^@rpath/'; then
    install_name_tool -add_rpath @executable_path/../lib "$out"
  fi
}
for spec in "${tools[@]}"; do
  embed_tool "${spec%%:*}" "${spec#*:}"
done
for name in "${ship_helpers[@]}"; do
  cp "$root/packaging/helpers/$name" "$app/Contents/Resources/bin/$name"
  chmod 755 "$app/Contents/Resources/bin/$name"
done
# Native atomic directory exchange. RENAME_SWAP has no window where the app
# path is absent; the executable is signed with the rest of the app below.
xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
  -o "$app/Contents/Resources/bin/mash-update-swap" \
  "$root/packaging/helpers/mash-update-swap.c"
cp "$root/packaging/lib.sh" "$app/Contents/Resources/bin/lib.sh"
cp "$root/packaging/herdr-pane" "$app/Contents/Resources/bin/herdr-pane"
cp "$root/packaging/mash-shell" "$app/Contents/Resources/bin/mash-shell"
cp "$wizard_bin" "$app/Contents/Resources/bin/mash-wizard"
cp "$root/packaging/mash" "$app/Contents/MacOS/mash"
chmod 755 "$app/Contents/MacOS/mash" \
  "$app/Contents/Resources/bin/herdr-pane" \
  "$app/Contents/Resources/bin/mash-shell" \
  "$app/Contents/Resources/bin/mash-wizard"
cp "$root/packaging/Mash.icns" "$app/Contents/Resources/Mash.icns"
cp -R "$root/packaging/defaults" "$app/Contents/Resources/defaults"
# zsh plugin code is shipped read-only; Mash's zshrc sources it from here.
mkdir -p "$app/Contents/Resources/share/zsh"
cp -R "$work/zsh-autosuggestions/zsh-autosuggestions-0.7.1" \
  "$app/Contents/Resources/share/zsh/zsh-autosuggestions"
# The wizard embeds this catalog at compile time and mash-voice-model reads it
# at runtime from Resources/defaults/pi/catalog. Both have to match the pi-voice
# the bundle actually ships; the shared stager checks that and copies them.
mash_stage_pi_voice_catalog "$app/Contents/Resources"
cp "$root/packaging/uninstall" "$app/Contents/Resources/uninstall"
chmod 755 "$app/Contents/Resources/uninstall"
# The agent directory needs its own node_modules for exactly one thing: the
# mash-orchestration extension imports `typebox` at runtime, and Node resolves
# that from the extension's directory upward. It cannot reach pi's own nested
# copy under node/lib/node_modules/@earendil-works/pi-coding-agent.
#
# The pi packages themselves do NOT belong here. `pi list` resolves every
# `npm:` specifier in settings.json to node/lib/node_modules, the global
# prefix, and nothing in pi joins the agent directory with node_modules.
# Installing the five packages here as well cost 449 MB of duplicated provider
# SDKs (@mariozechner, koffi, openai, @mistralai) to deliver a 5.9 MB module.
env HOME="$work/home" \
  npm_config_cache="$work/npm-cache" \
  npm_config_update_notifier=false \
  "$app/Contents/Resources/node/bin/npm" install --prefix "$app/Contents/Resources/defaults/pi" \
  typebox@1.3.36
mash_install_skills
export PATH="$work/rustc/bin:$work/go/bin:$app/Contents/Resources/bin:$PATH"
# The downloaded Go owns its own standard library. An inherited GOROOT (for
# example a Homebrew Go on PATH) makes its `compile` tool disagree with the
# `go` command about which release it is.
export GOROOT="$work/go"
export GOTOOLCHAIN=local
mash_build_fresh
mash_build_plugins

ditto "$ghostty_src" "$app/Contents/Resources/$terminal_app"
plist="$app/Contents/Resources/$terminal_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.mash.ghostty' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Mash' "$plist"
# The dock tile takes its artwork from the asset catalog whenever the app was
# built with a macOS 11+ SDK, and Ghostty's catalog holds only Ghostty icons.
# CFBundleIconName therefore has to be deleted or it keeps winning no matter
# what CFBundleIconFile says. With it gone the system falls back to
# CFBundleIconFile, which we point at Mash's own icon shipped beside
# Ghostty's. The name needs no such treatment: LaunchServices already sees
# CFBundleName/CFBundleDisplayName as Mash.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Mash' "$plist"
if /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Mash' "$plist" 2>/dev/null; then
  :
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Mash' "$plist"
fi
# The nested bundle kept Ghostty's placeholder 1 / 0.1 across every Mash
# build, so the app path, the bundle identifier and the version were all
# unchanged when Mash.icns was rewritten -- and the Dock went on drawing the
# previous icon from its cache until the cache expired. Observed after the
# ANSI-art icon landed: the running tile still showed the icon Mash used two
# releases earlier. Mash's own version makes each release a new identity to
# LaunchServices and Icon Services.
nested_version="$(tr -d '[:space:]' <"$root/VERSION")"
[ -n "$nested_version" ] || { echo "VERSION is empty." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $nested_version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $nested_version" "$plist"
# Bundled artwork and menus. Both edit files inside the copy, so they belong
# before any signing.
cp "$root/packaging/Mash.icns" "$app/Contents/Resources/$terminal_app/Contents/Resources/Mash.icns"
# The fork's MainMenu.xib carries the Mash names, so nothing is rewritten here.
# This only asserts the result: no compiled nib may still show Ghostty to a user.
"$app/Contents/Resources/python/bin/python3" "$root/packaging/check-nib-branding.py" \
  "$app/Contents/Resources/$terminal_app"
mash_install_fonts

# The app version is whatever VERSION holds; bumpversion is its only writer.
# Interpolated into the plist rather than patched in afterwards so there is no
# second literal here to drift out of sync.
version="$(tr -d '[:space:]' <"$root/VERSION")"
[ -n "$version" ] || { echo "VERSION is empty." >&2; exit 1; }
# The shared seed ownership helper needs the same release id on macOS as on
# Linux, where build-common.sh already stages Resources/VERSION.
printf '%s\n' "$version" >"$app/Contents/Resources/VERSION"

cat >"$app/Contents/Info.plist" <<EOF
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
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# The outer Mash.app is what Finder shows; its launcher exits as soon as
# Ghostty is up, so it never owns the dock tile, but it still needs an icon.
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Mash' "$app/Contents/Info.plist"

# Nothing anywhere in the bundle may still reference Homebrew. Scan every
# Mach-O we ship — tools, dylibs, nested bundles — not just the named few.
# Deliberately the last thing before signing, and after Fresh and the plugins
# are built: run any earlier and a dependency introduced by either of them
# escapes both this check and embed_deps above. That is how libexec/fresh
# The one agent-directory dependency has to be there, and resolvable from the
# extension directory rather than from pi's nested copy.
typebox_js="$app/Contents/Resources/defaults/pi/node_modules/typebox/build/index.mjs"
[ -f "$typebox_js" ] || {
  echo "typebox is missing from the agent directory; mash-orchestration cannot load" >&2
  exit 1
}
if ! env PATH="$app/Contents/Resources/node/bin:/usr/bin:/bin" \
  "$app/Contents/Resources/node/bin/node" -e \
  "require.resolve('typebox',{paths:['$app/Contents/Resources/defaults/pi/extensions']})" \
  >/dev/null 2>&1; then
  echo "the agent directory cannot resolve typebox from extensions/" >&2
  exit 1
fi

# Python writes __pycache__ into every installed package as it imports one.
# A shipped bundle never needs it: the interpreter regenerates the bytecode on
# the first import into the data folder's copy. Measured at 157 directories and
# 26 MB, all of it text that compresses badly in the disk image.
find "$app/Contents" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# shipped depending on /opt/homebrew/opt/xz/lib/liblzma.5.dylib.
while IFS= read -r -d '' macho; do
  if otool -L "$macho" 2>/dev/null | awk 'NR>1 {print $1}' | grep -q -E '^/opt/homebrew/|^@@HOMEBREW_'; then
    echo "still links Homebrew: ${macho#"$app"/}" >&2
    exit 1
  fi
done < <(find "$app/Contents" -type f -perm -u+x -print0 2>/dev/null)

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

# Notification Center names and illustrates an alert from the bundle that
# posted it, so the notifier's own identity is what the user reads -- not
# Mash.app's. Upstream ships it as "herdr" with Ghostty's Terminal.icns.
notifier_plist="$app/Contents/Resources/plugins/dot.terminal-notifier/assets/HerdrNotify.app/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName; do
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$notifier_plist" 2>/dev/null || true)"
  [ "$got" = "Mash" ] || {
    echo "notifier $key is '$got', not Mash: alerts would be attributed to it" >&2
    exit 1
  }
done
notifier_icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$notifier_plist" 2>/dev/null || true)"
[ "$notifier_icon" = "Mash" ] &&
  [ -f "$app/Contents/Resources/plugins/dot.terminal-notifier/assets/HerdrNotify.app/Contents/Resources/Mash.icns" ] || {
  echo "notifier icon is '$notifier_icon'; alerts would show Ghostty's artwork" >&2
  exit 1
}

# Reject the OpenCode and Rosey programs. pi ships provider modules whose
# filenames mention opencode; those are not the OpenCode app. Hindsight is no
# longer on this list: its warm-start starts a real daemon, and the first launch
# installs the environment into the data folder, so nothing named hindsight
# ships in the bundle either way.
for banned in opencode rosey; do
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
[ "$orig" = "com.mitchellh.ghostty" ] || {
  echo "forked Ghostty bundle id changed: $orig" >&2
  exit 1
}
[ "$copy" = "app.mash.ghostty" ] || {
  echo "copy bundle id is $copy" >&2
  exit 1
}
if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
  echo "Mash.app is running from $dest; leaving it in place." >&2
  exit 1
fi
rm -rf "$dest"
mv "$app" "$dest"
mash_finish_skill_venv "$dest/Contents/Resources" "$work/Mash.app/Contents/Resources"
mash_link_plugins "$dest" "$home"
# Again, and after mash_finish_skill_venv: that step imports pytest to prove the
# venv works, which re-creates __pycache__ inside it. This has to be the last
# thing before signing, or the bytecode it writes ships.
find "$dest/Contents" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
codesign --force --deep --sign - "$dest/Contents/Resources/$terminal_app"
codesign --force --sign - "$dest"
mash_write_pins
chmod -R u+w "$work" "$root/dist/.cargo" "$root/dist/.cargo-target" 2>/dev/null || true
rm -rf "$work" "$root/dist/.cargo" "$root/dist/.cargo-target"
echo "built $dest"
echo "version $version"
echo "forked Ghostty bundle id stayed $orig"
echo "Ghostty fork: $ghostty_fork @ $(git -C "$ghostty_fork" rev-parse --short HEAD)"
