#!/bin/bash
# Assemble dist/Mash.app. Downloads programs into dist/.build.
# Custom plugins, helpers, and fonts come from this repo.
# Writes only under this repo's dist/. Does not start Herdr.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
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
case "$(uname -m)" in
arm64 | x86_64) ;;
*)
  echo "Mash builds for arm64 or x86_64 macOS only." >&2
  exit 1
  ;;
esac
# The manifest target this build resolves every pinned artifact for. The Linux
# adapter derives it the same way; nothing may assume a literal. Apple silicon is
# the official, released build; Intel (macos-amd64) is built from source with the
# pins the manifest keeps for it.
target="$(python3 "$root/packaging/assets.py" target)"
case "$target" in
macos-arm64 | macos-amd64) ;;
*)
  echo "expected target macos-arm64 or macos-amd64, resolved $target" >&2
  exit 1
  ;;
esac

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
  herdr-tabs
  herdr_tabs.py
  herdr-fresh-shell-pane
  herdr-annotate-paste
  mash-orchestration
  mash-hindsight-install
  mash-tool-install
  mash-tool-refresh
  hindsight-embed
  mash-voice-model
  mash-pi-models.mjs
  mash-pi-runtime.mjs
  mash-pi-credentials.mjs
  mash-pi-connect.mjs
  mash-pi-http.mjs
  mash-notify
  mash-seed-sync
  mash-t
  mash-update-notice
  mash-pane-resume
  mash-stop-sessions
  mash-update-verify
  mash-update-apply
  mash-update-common
  mash-update-gate
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

# Herdr is the one component still fetched here: macOS takes it from a Homebrew
# bottle whose dylibs are rewritten into the bundle below, which the shared
# stager (a single pinned binary) does not model. Everything else now comes
# from the manifest through mash_stage_runtimes, so a version lives in exactly
# one place. None of the opt-in host utilities are downloaded; Git comes from
# the build machine for plugin source clones.
mash_resolve herdr "$target" || {
  echo "could not resolve the pinned herdr bottle" >&2
  exit 1
}
case "$URL" in
https://ghcr.io/*)
  fetch_bottle herdr "$URL" "$SHA256"
  take_bin herdr "$(bottle_bin herdr herdr)"
  ;;
*)
  # A plain release binary (macos-amd64). It links only system libraries, so
  # there is no bottle and nothing to embed.
  mash_fetch_pinned herdr "$target" "$work/tools" || {
    echo "could not stage the pinned herdr binary" >&2
    exit 1
  }
  ;;
esac

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
case "$(uname -m)" in
arm64) zig_arch=aarch64 ;;
*) zig_arch=x86_64 ;;
esac
ghostty_zig_url="https://ziglang.org/download/$ghostty_zig_version/zig-$zig_arch-macos-$ghostty_zig_version.tar.xz"
zig_bin="/Volumes/Documents/Software/tools/zig-$ghostty_zig_version/zig"
[ -x "$zig_bin" ] || zig_bin="$home/Development/tools/zig-$ghostty_zig_version/zig"
# The identifier is Xcode-version-specific, so it is read back from the Xcode
# in use rather than hardcoded: an Xcode update changes it, and `xcrun metal`
# fails for a known-but-uninstalled toolchain while silently ignoring an
# unknown one -- so a stale pin fails the build with "Metal Toolchain is
# unavailable" even when the component is installed. CI reads it back the same
# way on its own runner.
ghostty_metal_toolchain="${MASH_METAL_TOOLCHAIN:-$(xcodebuild -showComponent MetalToolchain 2>/dev/null | sed -n 's/^Toolchain Identifier: //p')}"
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

# Rust and Go build Fresh, the wizard and two plugins. Build-only, pinned in
# the manifest for every target, and cached between runs like the Linux build.
mash_ensure_toolchain rust "$target" "$work/rustc" || {
  echo "could not stage the rust toolchain" >&2
  exit 1
}
mash_ensure_toolchain go "$target" "$work/go" || {
  echo "could not stage the go toolchain" >&2
  exit 1
}

# Only herdr needs its Homebrew dylibs embedded; the rest are self-contained
# and are staged straight into the bundle by mash_stage_runtimes.
tools=(
  "herdr:$work/tools/herdr"
)

if ps -ax -o command= | grep -F "$dest/" | grep -v grep >/dev/null; then
  echo "Mash.app is running from $dest; leaving it in place." >&2
  exit 1
fi

# Mash.app IS the terminal: the fork's built app is the bundle, and everything
# Mash ships is added to its Resources. One app is what macOS saves and reopens
# after a restart, what the Dock tile belongs to, and what the microphone
# prompt names -- a terminal nested behind a launcher got none of those right.
# The terminal's executable hands every launch to Resources/bin/mash-launch
# before it initializes (the fork's main.swift), which seeds ~/.mash and execs
# it back with Mash's environment.
rm -rf "$app"
ditto "$ghostty_src" "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/lib"

# The runtimes, the Pi packages, the bundled tools and the zsh plugin, all from
# the manifest. The same call serves the Linux build, so a pin is honoured
# identically on both platforms and lives in exactly one file.
MASH_CACHE="$work/cache" mash_stage_runtimes "$app/Contents/Resources" "$target" || {
  echo "could not stage the runtimes" >&2
  exit 1
}

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
xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
  -o "$app/Contents/Resources/bin/mash-update-processes" \
  "$root/packaging/helpers/mash-update-processes.c"
# Executed only from a copy outside the bundle. An image under Mash.app is
# counted as a running Mash and blocks the swap.
xcrun --sdk macosx clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 \
  -fobjc-arc -framework AppKit \
  -o "$app/Contents/Resources/bin/mash-update-progress" \
  "$root/packaging/helpers/mash-update-progress.m"
cp "$root/packaging/lib.sh" "$app/Contents/Resources/bin/lib.sh"
cp "$root/packaging/launch-common.sh" "$app/Contents/Resources/bin/launch-common.sh"
cp "$root/packaging/herdr-pane" "$app/Contents/Resources/bin/herdr-pane"
cp "$root/packaging/mash-shell" "$app/Contents/Resources/bin/mash-shell"
cp "$wizard_bin" "$app/Contents/Resources/bin/mash-wizard"
# The terminal execs this before it initializes; see packaging/mash.
cp "$root/packaging/mash" "$app/Contents/Resources/bin/mash-launch"
chmod 755 "$app/Contents/Resources/bin/mash-launch" \
  "$app/Contents/Resources/bin/launch-common.sh" \
  "$app/Contents/Resources/bin/herdr-pane" \
  "$app/Contents/Resources/bin/mash-shell" \
  "$app/Contents/Resources/bin/mash-wizard"
cp "$root/packaging/Mash.icns" "$app/Contents/Resources/Mash.icns"
# Shared runtime staging already created defaults/pi; merge without nesting.
cp -R "$root/packaging/defaults/." "$app/Contents/Resources/defaults/"
# The language table and the message catalogs. Every Mash component reads them
# from the staged tree: mash-t and the helpers through MASH_I18N_DIR, the Pi
# extensions and the Fresh plugin through the same variable. The Linux build
# gets them from mash_stage_portable_payload; this build stages file by file.
mkdir -p "$app/Contents/Resources/i18n"
cp -R "$root/packaging/i18n/." "$app/Contents/Resources/i18n/"
# The wizard's Mash-owned npm installer and host pip installer resolve pinned
# versions from this manifest. Both refuse an unpinned network install.
mkdir -p "$app/Contents/Resources/assets"
cp "$root/packaging/assets.json" "$root/packaging/assets.py" \
  "$app/Contents/Resources/assets/"
chmod 644 "$app/Contents/Resources/assets/assets.json"
chmod 755 "$app/Contents/Resources/assets/assets.py"
# The zsh plugin and the Pi Voice catalog come from mash_stage_runtimes above,
# which both adapters call.
cp "$root/packaging/uninstall" "$app/Contents/Resources/uninstall"
chmod 755 "$app/Contents/Resources/uninstall"
mash_install_skills
export PATH="$work/rustc/bin:$work/go/bin:$app/Contents/Resources/bin:$PATH"
# The downloaded Go owns its own standard library. An inherited GOROOT (for
# example a Homebrew Go on PATH) makes its `compile` tool disagree with the
# `go` command about which release it is.
export GOROOT="$work/go"
export GOTOOLCHAIN=local
mash_build_fresh
mash_build_plugins

# The bundle's identity. Ghostty's plist is the base -- it carries the document
# types, Services, AppleScript dictionary, Dock tile plugin, fonts path and the
# usage strings its process needs -- and Mash replaces what names the app.
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.mash' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Mash' "$plist"
if /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Mash' "$plist" 2>/dev/null; then
  :
else
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Mash' "$plist"
fi
# The dock tile takes its artwork from the asset catalog whenever the app was
# built with a macOS 11+ SDK, and Ghostty's catalog holds only Ghostty icons.
# CFBundleIconName therefore has to be deleted or it keeps winning no matter
# what CFBundleIconFile says. With it gone the system falls back to
# CFBundleIconFile, which points at Mash's own icon.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Mash' "$plist"
cp "$root/packaging/Mash.icns" "$app/Contents/Resources/Mash.icns"
# TCC refuses to raise a microphone or camera prompt for a bundle that carries
# no purpose string, and the refusal is silent: the capture stream opens and
# delivers nothing but zeros. Ghostty's say "Mash Terminal"; the prompt names
# the app, so they name Mash.
/usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription A program running within Mash would like to use your microphone.' "$plist"
/usr/libexec/PlistBuddy -c 'Set :NSCameraUsageDescription A program running within Mash would like to use the camera.' "$plist"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$plist"

# The app version is whatever VERSION holds; bumpversion is its only writer.
# Each release is also a new identity to LaunchServices and Icon Services:
# with a fixed version the Dock went on drawing a previous icon from its cache
# after Mash.icns changed.
version="$(tr -d '[:space:]' <"$root/VERSION")"
[ -n "$version" ] || { echo "VERSION is empty." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist"
# Rollback is allowed only when both signed builds explicitly declare the
# same app data schema AND identical bundled component pins. Bump the schema
# prefix when Mash-owned persistent data becomes incompatible.
data_compat="v1:$(shasum -a 256 "$root/packaging/pins.txt" | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Add :MashUpdateDataCompatibility string $data_compat" "$plist"
# The shared seed ownership helper needs the same release id on macOS as on
# Linux, where build-common.sh already stages Resources/VERSION.
printf '%s\n' "$version" >"$app/Contents/Resources/VERSION"
# A release publishes a DMG for each macOS target listed here, so those builds
# update themselves like any other. A target outside this set has no release
# channel of its own, and this marker keeps mash-update-notice from asking
# GitHub or offering it a download built for a different CPU.
case "$target" in
macos-arm64 | macos-amd64) ;;
*)
  printf 'No release channel for %s; updates are disabled in this build.\n' "$target" \
    >"$app/Contents/Resources/updates-disabled"
  ;;
esac

# The fork's MainMenu.xib carries the Mash names, so nothing is rewritten here.
# This only asserts the result: no compiled nib may still show Ghostty to a user.
"$app/Contents/Resources/python/bin/python3" "$root/packaging/check-nib-branding.py" "$app"
mash_install_fonts

# Verify only after runtimes, helpers, defaults and VERSION are staged, and
# before signing. Both platform adapters run this same payload/runtime gate.
mash_verify_portable_payload "$app/Contents/Resources" || {
  echo "the macOS payload is incomplete" >&2
  exit 1
}

# Python writes __pycache__ into every installed package as it imports one.
# A shipped bundle never needs it: the interpreter regenerates the bytecode on
# the first import into the data folder's copy. Measured at 157 directories and
# 26 MB, all of it text that compresses badly in the disk image.
find "$app/Contents" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# Nothing anywhere in the bundle may still reference Homebrew. Scan every
# Mach-O we ship — tools, dylibs, nested bundles — not just the named few.
# Deliberately the last thing before signing, and after Fresh and the plugins
# are built: run any earlier and a dependency introduced by either of them
# escapes both this check and embed_deps above. That is how libexec/fresh
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
[ "$copy" = "app.mash" ] || {
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
# The app's own executable and its Dock tile plugin, then the bundle seal over
# everything above. release.sh re-signs all of it with the Developer ID.
codesign --force --deep --sign - "$dest/Contents/PlugIns/DockTilePlugin.plugin"
codesign --force --sign - "$dest"
mash_write_pins
chmod -R u+w "$work" "$root/dist/.cargo" "$root/dist/.cargo-target" 2>/dev/null || true
rm -rf "$work" "$root/dist/.cargo" "$root/dist/.cargo-target"
echo "built $dest"
echo "version $version"
echo "forked Ghostty bundle id stayed $orig"
echo "Ghostty fork: $ghostty_fork @ $(git -C "$ghostty_fork" rev-parse --short HEAD)"
