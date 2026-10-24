#!/bin/bash
# Fresh, plugins, fonts, and pins for packaging/build.sh.
# Sourced by that script. Writes only under the repo dist/ and, once, pins.txt.

mash_assets() {
  python3 "${MASH_ASSETS_PY:-$root/packaging/assets.py}" "$@"
}

# Resolve one pinned component for one target into shell variables. Callers get
# exactly the artifact the manifest names, or a hard failure -- never a host
# binary that happens to share the name.
mash_resolve() {
  local spec
  spec="$(mash_assets resolve-shell "$1" "$2")" || return 1
  eval "$spec"
}

# Download, verify, and extract one pinned component into a directory.
mash_fetch_pinned() {
  local component="$1" target="$2" outdir="$3" tmp
  local COMPONENT TARGET STRATEGY VERSION URL SHA256 ARCHIVE MEMBER
  mash_resolve "$component" "$target" || {
    echo "cannot resolve $component for $target" >&2
    return 1
  }
  [ -n "${URL:-}" ] || {
    echo "$component for $target is not a downloaded artifact" >&2
    return 1
  }
  tmp="$(mktemp -d)"
  curl -fL --retry 2 --max-time 600 -o "$tmp/archive" "$URL" || {
    echo "could not download $component $VERSION for $target" >&2
    rm -rf "$tmp"
    return 1
  }
  echo "$SHA256  $tmp/archive" | sha256sum -c - >/dev/null || {
    echo "$component $VERSION for $target failed its checksum" >&2
    rm -rf "$tmp"
    return 1
  }
  mkdir -p "$outdir"
  case "$ARCHIVE" in
  tar.gz) tar -xzf "$tmp/archive" -C "$tmp" ;;
  tar.xz) tar -xJf "$tmp/archive" -C "$tmp" ;;
  zip) unzip -q "$tmp/archive" -d "$tmp" ;;
  gz) gunzip -c "$tmp/archive" >"$tmp/$MEMBER" ;;
  raw) cp "$tmp/archive" "$tmp/$MEMBER" ;;
  *)
    echo "$component: unsupported archive $ARCHIVE" >&2
    rm -rf "$tmp"
    return 1
    ;;
  esac
  [ -f "$tmp/$MEMBER" ] || {
    echo "$component archive has no $MEMBER" >&2
    rm -rf "$tmp"
    return 1
  }
  # Install under the name callers run, not the release asset's name: a raw
  # download is called herdr-linux-x86_64 but every caller execs `herdr`.
  local install_name
  install_name="$(basename "$MEMBER")"
  case "$ARCHIVE" in
  raw) install_name="$component" ;;
  esac
  cp "$tmp/$MEMBER" "$outdir/$install_name"
  chmod 755 "$outdir/$install_name"
  rm -rf "$tmp"
}

# Stage the Linux-only half of the payload: the pinned Herdr binary for this
# architecture. Everything portable is already in place from the shared staging.
mash_stage_linux_runtime() {
  local product="$1" target="$2"
  mash_fetch_pinned herdr "$target" "$product/bin" || {
    echo "could not stage herdr for $target" >&2
    return 1
  }
  return 0
}

# Download one pinned component and extract its whole archive into a directory.
# mash_fetch_pinned() above extracts a single named member; runtimes are trees,
# so they need the archive itself.
mash_fetch_tree() {
  local component="$1" target="$2" outdir="$3" tmp
  local COMPONENT TARGET STRATEGY VERSION URL SHA256 ARCHIVE MEMBER
  mash_resolve "$component" "$target" || return 1
  [ -n "${URL:-}" ] || {
    echo "$component for $target is not a downloaded artifact" >&2
    return 1
  }
  tmp="$(mktemp -d)"
  curl -fL --retry 2 --max-time 900 -o "$tmp/archive" "$URL" || {
    echo "could not download $component $VERSION for $target" >&2
    rm -rf "$tmp"
    return 1
  }
  echo "$SHA256  $tmp/archive" | sha256sum -c - >/dev/null || {
    echo "$component $VERSION for $target failed its checksum" >&2
    rm -rf "$tmp"
    return 1
  }
  mkdir -p "$tmp/x"
  case "$ARCHIVE" in
  tar.gz) tar -xzf "$tmp/archive" -C "$tmp/x" ;;
  tar.xz) tar -xJf "$tmp/archive" -C "$tmp/x" ;;
  zip) unzip -q "$tmp/archive" -d "$tmp/x" ;;
  *)
    echo "$component: unsupported archive $ARCHIVE for tree extraction" >&2
    rm -rf "$tmp"
    return 1
    ;;
  esac
  mkdir -p "$outdir"
  cp -R "$tmp/x/." "$outdir/"
  rm -rf "$tmp"
  printf '%s\n' "$MEMBER" >"$outdir/.mash-member"
}

# The readable pin list is a projection of packaging/assets.json, which is the
# single authority for every pinned version and checksum. Nothing here may hard
# code a version again: one that disagrees with the manifest is exactly the drift
# mash_pins_check exists to catch.
# The resource root the active adapter is staging into. packaging/build.sh
# sets it to the app's Contents/Resources; packaging/build-linux.sh sets it to
# the package's /opt/letsmash. Nothing shared below may reconstruct either path,
# which is what lets one set of staging functions serve both products.
mash_res() { printf '%s\n' "${MASH_RES_ROOT:?MASH_RES_ROOT is not set by the adapter}"; }

# The pinned version of one component, from the manifest alone. Callers must not
# hard-code a version: a package spec without one makes npm install whatever is
# current, which is how a build silently ships an unpinned agent runtime.
mash_version() {
  local version
  version="$(mash_assets pins | sed -n "s/^$1 //p")"
  if [ -z "$version" ]; then
    echo "no pinned version for $1" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

mash_pins_text() {
  mash_assets pins
}

mash_pins_check() {
  local pins="$root/packaging/pins.txt"
  if ! mash_assets validate; then
    echo "packaging/assets.json is not valid. Leaving dist/Mash.app in place." >&2
    exit 1
  fi
  [ -f "$pins" ] || return 0
  if ! mash_assets check "$pins"; then
    echo "packaging/pins.txt does not match packaging/assets.json. Leaving dist/Mash.app in place." >&2
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
    "MesloLGS NF Bold Italic.ttf"; do
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
  [ -f "$root/packaging/uninstall" ] || {
    echo "missing uninstall" >&2
    exit 1
  }
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

# Build Ghostty from Mash's fork instead of downloading the upstream release.
# The fork is where Mash owns the menus, the About panel, and anything else
# that upstream hardcodes in Swift and no bundle key can reach.
#
# Two host requirements that are easy to get wrong, so they are checked here:
#   * Zig. Upstream pins it, and the pin matters: 0.15.2 cannot compile for
#     this machine's native target at all (it fails to link libc, even for an
#     empty project), which is why the fork tracks a branch on 0.16.0.
#   * Metal Toolchain. Xcode does not install it by default, and the stock
#     `metal` shim stays broken until TOOLCHAINS names the downloaded one.
mash_build_ghostty() {
  local src="${MASH_GHOSTTY_SRC:-$ghostty_fork}"
  local zig="${MASH_ZIG:-$zig_bin}"

  [ -d "$src/.git" ] || {
    echo "Ghostty fork is missing at $src" >&2
    echo "Clone it or set MASH_GHOSTTY_SRC." >&2
    exit 1
  }
  [ -x "$zig" ] || {
    echo "zig $ghostty_zig_version is missing at $zig" >&2
    echo "Set MASH_ZIG, or unpack it from $ghostty_zig_url" >&2
    exit 1
  }
  local have
  have="$("$zig" version)"
  [ "$have" = "$ghostty_zig_version" ] || {
    echo "zig is $have, want $ghostty_zig_version" >&2
    exit 1
  }
  command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1 || {
    echo "xcodebuild needs a full Xcode (xcode-select -s /Applications/Xcode.app)." >&2
    exit 1
  }
  TOOLCHAINS="$ghostty_metal_toolchain" xcrun metal --version >/dev/null 2>&1 || {
    echo "Metal Toolchain is unavailable." >&2
    echo "Install it: sudo xcodebuild -downloadComponent MetalToolchain" >&2
    echo "Then confirm the identifier: xcodebuild -showComponent MetalToolchain" >&2
    exit 1
  }

  local commit
  commit="$(git -C "$src" rev-parse --short HEAD)"
  echo "building Ghostty from $src @ $commit"

  # GhosttyKit is the Zig core the Swift app links against. Built release,
  # without the app: xcodebuild produces that part.
  (
    cd "$src"
    PATH="$(dirname "$zig"):$PATH" \
      TOOLCHAINS="$ghostty_metal_toolchain" \
      "$zig" build -Doptimize=ReleaseFast -Demit-macos-app=false
  ) || { echo "GhosttyKit build failed." >&2; exit 1; }

  # The app itself. Upstream's CI notes this must not run under Nix; we never
  # do, but keep the environment minimal for the same reason.
  (
    cd "$src/macos"
    TOOLCHAINS="$ghostty_metal_toolchain" \
      xcodebuild -target Ghostty -configuration Release
  ) || { echo "Ghostty.app build failed." >&2; exit 1; }

  local built="$src/macos/build/Release/Ghostty.app"
  [ -d "$built" ] || { echo "Ghostty.app was not produced at $built" >&2; exit 1; }
  rm -rf "$work/Ghostty.app"
  ditto "$built" "$work/Ghostty.app"
  # Record what went in, so the bundle can be traced back to a fork commit.
  /usr/libexec/PlistBuddy -c "Add :MashGhosttyCommit string $commit" \
    "$work/Ghostty.app/Contents/Info.plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Set :MashGhosttyCommit $commit" \
      "$work/Ghostty.app/Contents/Info.plist"
}

mash_build_fresh() {
  local tarball="$work/fresh.tar.gz"
  curl -fL --retry 2 --max-time 300 -o "$tarball" \
    "https://github.com/sinelaw/fresh/archive/refs/tags/v0.5.1.tar.gz"
  tar -xzf "$tarball" -C "$work"
  local src="$work/fresh-0.5.1"
  grep -q 'version = "0.5.1"' "$src/Cargo.toml"
  # Every patch here is Mash-owned and rebased onto the pinned tag, so a
  # failure means upstream moved under it. Naming the patch in the message is
  # what makes that a one-minute fix instead of a bisect. herdr-workspace's
  # patch is deliberately absent: it targets a plugin, not Fresh.
  for name in fresh-config-dir fresh-reveal-in-finder; do
    if ! patch -p1 -d "$src" <"$root/packaging/patches/$name.patch"; then
      echo "$name.patch did not apply. Leaving dist/Mash.app in place." >&2
      exit 1
    fi
  done
  # liblzma-sys probes pkg-config and takes Homebrew's shared liblzma
  # whenever it finds one, which left libexec/fresh loading
  # /opt/homebrew/opt/xz/lib/liblzma.5.dylib at runtime. Inside the signed,
  # hardened bundle that dylib is another team's, so dyld aborts the
  # process. LZMA_API_STATIC makes the crate build its vendored copy
  # instead, and the binary ends up with no external dependency at all.
  LZMA_API_STATIC=1 mash_cargo "$src/Cargo.toml" fresh
  local bin="$root/dist/.cargo-target/fresh/release/fresh"
  [ -x "$bin" ] || {
    echo "Fresh binary was not produced." >&2
    exit 1
  }
  mkdir -p "$(mash_res)/libexec"
  cp "$bin" "$(mash_res)/libexec/fresh"
  chmod 755 "$(mash_res)/libexec/fresh"
  cat >"$(mash_res)/bin/fresh" <<'EOF'
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
  chmod 755 "$(mash_res)/bin/fresh"
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
  local plugins="$(mash_res)/plugins"
  local src="$root/packaging/plugins"
  mkdir -p "$plugins" "$work/src"
  local name
  # image-popup belongs here: the Fresh-side package that ships in
  # defaults/fresh/plugins/packages/mash-image-popup opens a Herdr pane with
  # `--plugin image-popup`, so leaving the Herdr half out registered that pane
  # from the build machine's source checkout and broke show_file anywhere else.
  for name in cache-hit dev-tab fingers fork-from-message herdr-orchestration \
    image-popup pr-watch-focus; do
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
  (cd "$plugins/fullerzz.sesh" && mash_go "$plugins/fullerzz.sesh" \
    -ldflags="-X=github.com/fullerzz/herdr-plugin-sesh/internal/app.Version=0.14.0" \
    -o bin/herdr-sesh ./cmd/herdr-sesh)

  git clone --depth 1 --branch v0.9.1 \
    https://github.com/kryptamine/herdr-auto-title.git "$work/src/auto-title"
  mash_copy_tree "$work/src/auto-title" "$plugins/herdr.auto-title"
  (cd "$plugins/herdr.auto-title" && mash_go "$plugins/herdr.auto-title" \
    -o herdr-auto-title ./cmd/herdr-auto-title)

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
  (cd "$work/src/annotate" && bash scripts/fetch-herdr-annotate.sh)
  mash_copy_tree "$work/src/annotate" "$plugins/annotate"
}

mash_install_fonts() {
  local fonts="$(mash_res)/$terminal_app/Contents/Resources/Fonts"
  local font
  mkdir -p "$fonts"
  for font in \
    "MesloLGS NF Regular.ttf" \
    "MesloLGS NF Bold.ttf" \
    "MesloLGS NF Italic.ttf" \
    "MesloLGS NF Bold Italic.ttf"; do
    cp "$root/packaging/fonts/$font" "$fonts/$font"
  done
  cp "$root/packaging/fonts/NOTICE.txt" "$fonts/NOTICE.txt"
  local plist="$(mash_res)/$terminal_app/Contents/Info.plist"
  if /usr/libexec/PlistBuddy -c 'Set :ATSApplicationFontsPath Fonts' "$plist" 2>/dev/null; then
    :
  else
    /usr/libexec/PlistBuddy -c 'Add :ATSApplicationFontsPath string Fonts' "$plist"
  fi
}

mash_link_plugins() {
  local dest="$1"
  local home="$2"
  local sock="$dest/Contents/Resources/.plugin-link"
  local throwaway="$sock/config"
  local listed="$throwaway/herdr/plugins.json"
  local dir
  mkdir -p "$throwaway" "$sock/state" "$sock/data" "$sock/cache"
  for dir in "$dest/Contents/Resources/plugins"/*; do
    if [ -f "$dir/lite/herdr-plugin.toml" ]; then
      dir="$dir/lite"
    fi
    [ -f "$dir/herdr-plugin.toml" ] || continue
    env -u HERDR_CONFIG_PATH -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH \
      HOME="$home" \
      XDG_CONFIG_HOME="$throwaway" \
      XDG_STATE_HOME="$sock/state" \
      XDG_DATA_HOME="$sock/data" \
      XDG_CACHE_HOME="$sock/cache" \
      "$dest/Contents/Resources/bin/herdr" plugin link "$dir"
  done
  [ -f "$listed" ] || {
    echo "herdr linked no plugins at all." >&2
    exit 1
  }
  grep -q "$dest/Contents/Resources/plugins" "$listed" || {
    echo "a linked plugin does not point inside the bundle." >&2
    exit 1
  }
  rm -rf "$sock"
}

# Stop before packaging/build.sh replaces dist/Mash.app when the checkout is
# missing or is not the pinned release. Does not read or write personal trees.
mash_require_skills() {
  local src ver
  src="$(mash_skills_src)"
  if [ ! -f "$src/VERSION" ]; then
    echo "Mash Programming Skills checkout is missing at $src." >&2
    echo "Set MASH_SKILLS_SRC to a checkout of the pinned release." >&2
    exit 1
  fi
  ver="$(tr -d '[:space:]' <"$src/VERSION")"
  if [ "$ver" != "0.5.15" ]; then
    echo "Mash Programming Skills VERSION is $ver, want 0.5.15." >&2
    exit 1
  fi
}

mash_skills_src() {
  printf '%s\n' "${MASH_SKILLS_SRC:-$home/Development/mash-programming-skills}"
}

# Copy the pinned checkout into the staged app. The checkout itself is not edited.
mash_install_skills() {
  local src pi cfg name destskill
  mash_require_skills
  src="$(mash_skills_src)"
  pi="$(mash_res)/defaults/pi"
  cfg="$(mash_res)/defaults/mash-config"
  case "$pi" in
  "$(mash_res)/defaults/pi") ;;
  *)
    echo "refusing to install skills outside the staged app" >&2
    exit 1
    ;;
  esac
  mkdir -p "$pi/skills" "$pi/agents" "$pi/extensions" "$pi/scripts" \
    "$cfg/references/model-tiers"
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
  # Mash's own skills, authored in this repository rather than in the Mash
  # Programming Skills checkout, so the customization guide ships with the app
  # instead of existing only in one machine's data folder.
  for name in "$root/packaging/skills"/*; do
    [ -d "$name" ] || continue
    destskill="$pi/skills/$(basename "$name")"
    rm -rf "$destskill"
    mkdir -p "$destskill"
    tar -C "$name" --exclude '.git' --exclude '__pycache__' -cf - . |
      tar -C "$destskill" -xf -
  done
  rm -rf "$pi/agents"
  mkdir -p "$pi/agents"
  tar -C "$src/src/agents" --exclude '.git' -cf - . | tar -C "$pi/agents" -xf -
  cp "$src/references/model-tiers/model-tiers.md" "$cfg/references/model-tiers/model-tiers.md"
  cp "$src/references/markdown-rendering.md" "$cfg/references/markdown-rendering.md"
  mash_write_pi_guidance "$pi/AGENTS.md"
  mash_write_append_system "$src" "$pi/APPEND_SYSTEM.md"
  mash_rewrite_skill_paths "$pi" "$cfg/references"
  mash_write_hindsight_extension "$pi"
  printf '0.8.3\n' >"$cfg/hindsight-pin"
  mash_write_hindsight_config "$cfg"
  mash_build_parallel_venv "$cfg/venvs/mash-parallel"
  [ -f "$pi/skills/mash-plan/SKILL.md" ] || {
    echo "mash-plan was not staged" >&2
    exit 1
  }
  [ -f "$pi/skills/mash-customize/SKILL.md" ] || {
    echo "mash-customize was not staged" >&2
    exit 1
  }
  grep -q 'mash-customize' "$pi/APPEND_SYSTEM.md" || {
    echo "APPEND_SYSTEM.md does not point at mash-customize" >&2
    exit 1
  }
  grep -q 'HOME. is not changed' "$pi/APPEND_SYSTEM.md" || {
    echo "APPEND_SYSTEM.md is missing the Mash environment section" >&2
    exit 1
  }
  # The rewrite pass must not have touched the sentence that names the user's
  # own Pi, or it would read as Mash's own directory.
  grep -q '\$HOME/\.pi/agent' "$pi/APPEND_SYSTEM.md" || {
    echo "APPEND_SYSTEM.md lost the distinction between Mash's Pi and the user's" >&2
    exit 1
  }
  # The guidance ships to every user, so it must not name the machine that
  # built it: a checkout path or a home directory is meaningless anywhere else
  # and points the agent at a directory that does not exist. Checked on the
  # staged tree so the build's own rewrite pass is covered too.
  if grep -rlE '/Volumes/|/Users/' "$pi/APPEND_SYSTEM.md" "$pi/AGENTS.md" \
    "$pi/skills/mash-customize" >/dev/null 2>&1; then
    echo "Mash's pi guidance names a path on the build machine" >&2
    exit 1
  fi
  [ -d "$pi/agents" ] || {
    echo "agents were not staged" >&2
    exit 1
  }
  [ -f "$pi/APPEND_SYSTEM.md" ] || {
    echo "APPEND_SYSTEM.md was not staged" >&2
    exit 1
  }
  grep -q '"context7"' "$pi/mcp.json" || {
    echo "mcp.json is missing context7" >&2
    exit 1
  }
  # The skills for these three ship with Mash. Without the entries they load
  # and then fail on the missing tool, which is worse than not shipping them.
  # The binaries arrive through the wizard, not this bundle.
  for server in sentrux cua-driver agent-browser; do
    grep -q "\"$server\"" "$pi/mcp.json" || {
      echo "mcp.json is missing $server" >&2
      exit 1
    }
  done
  if grep -q 'github' "$pi/mcp.json"; then
    echo "mcp.json must not carry a GitHub token" >&2
    exit 1
  fi
  # The warm-start must reach the daemon through Mash's own shim, never by bare
  # name: the inherited PATH still holds the owner's ~/.local/bin, where their
  # own hindsight-embed install lives. The two checks below are the whole
  # requirement, so there is no separate "starts the daemon" grep on the bare
  # name -- the script stopped naming it that way when it moved to "$EMBED",
  # and a literal 'hindsight-embed daemon start' left in the validator failed
  # every build after that rewrite.
  # HOME must be redirected before any hindsight call, or the daemon writes
  # into the user's real ~/.hindsight and ~/.pg0.
  if ! grep -q 'export HOME="$data"' "$pi/scripts/ensure-hindsight-daemon.sh"; then
    echo "Hindsight warm-start does not isolate HOME" >&2
    exit 1
  fi
  # HOME alone is not enough: HuggingFace resolves its cache from
  # $HOME/.cache/huggingface unless HF_HOME says otherwise, so a warm-start
  # without it re-creates ~/.mash/.cache instead of using Mash's cache.
  if ! grep -q 'export HF_HOME HUGGINGFACE_HUB_CACHE' "$pi/scripts/ensure-hindsight-daemon.sh" ||
    ! grep -q 'export HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR' "$pi/scripts/ensure-hindsight-daemon.sh"; then
    echo "Hindsight warm-start does not pin the HuggingFace cache" >&2
    exit 1
  fi
  # Both providers default to `local`, which needs sentence-transformers. Mash
  # installs the slim package, so the config has to name the providers it can
  # actually load. Without these the daemon boots and then dies.
  for key in HINDSIGHT_API_EMBEDDINGS_PROVIDER HINDSIGHT_API_RERANKER_PROVIDER; do
    grep -q "^$key=" "$cfg/hindsight-embed.env" || {
      echo "the Hindsight config does not set $key" >&2
      exit 1
    }
  done
  # Every hindsight call must go through Mash's own shim. A bare name at the
  # start of a command would resolve to the owner's install, which sits on the
  # inherited PATH.
  if ! grep -q '"$EMBED" daemon start' "$pi/scripts/ensure-hindsight-daemon.sh"; then
    echo "Hindsight warm-start does not start Mash's own shim" >&2
    exit 1
  fi
  if grep -qE '^[[:space:]]*hindsight-embed ' "$pi/scripts/ensure-hindsight-daemon.sh"; then
    echo "Hindsight warm-start calls hindsight-embed by name, not by path" >&2
    exit 1
  fi
}

mash_write_pi_guidance() {
  cat >"$1" <<'EOF'
# Mash Programming Skills Agent Guidance

This file contains universal Mash Programming Skills workflow guidance only. It does not replace project-specific instructions in a repository's own AGENTS.md.

## Pi surfaces

- Always-on rules: `~/.mash/pi/agent/APPEND_SYSTEM.md`
- Skills: `~/.mash/pi/agent/skills/`
- Specialist agents: `~/.mash/pi/agent/agents/`
- Shared references: `~/.mash/config/mash/references/`
- Hindsight pin: `~/.mash/config/mash/hindsight-pin`

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
    echo "Auto-generated from src/rules/*.mdc with alwaysApply: true, preceded by"
    echo "a hand-written description of the Mash environment."
    echo "Shipped with Mash. Do not edit by hand."
    echo
    # $HOME and not ~ for the user's own Pi on purpose: the rewrite pass below
    # replaces ~/.pi/agent with Mash's path, which would invert the meaning of
    # the one sentence that has to name both directories.
    cat <<'EOF'
## The Mash environment

Mash is an isolated application: a signed bundle at `/Applications/Mash.app`
plus a writable data folder at `~/.mash`. Do not confuse the two.

- **`HOME` is not changed.** It is still the real home, so `~/.config`,
  `$HOME/.pi` and `$HOME/.hindsight` resolve to the user's own files. Mash's
  isolation comes only from environment variables.
- **Everything Mash owns is under `~/.mash`**: config in `~/.mash/config`,
  Pi's agent directory at `~/.mash/pi/agent`, tool state in `~/.mash/local`.
- **`Contents/` inside the bundle is signed and read-only.** Never write there.
  A change to anything inside it is made in Mash's source repository
  (https://github.com/LuisAlejandro/mash) and ships with a rebuild.
- **Two exceptions to the flat layout**: `.hindsight` and `.pg0`, directly
  under `~/.mash`, keep their leading dots because Hindsight and its embedded
  Postgres name those directories themselves.

Customizing Pi inside Mash means writing to its agent directory
(`~/.mash/pi/agent`), never to `$HOME/.pi/agent`: `settings.json` for settings,
`extensions/` for TypeScript extensions, `mcp.json` for MCP servers, `skills/`
for skills. Edits persist; the launcher seeds a file only when it is missing.

Packages install at runtime. `pi install npm:<name>` run in a Mash pane puts the
package in `~/.mash/pi/agent/npm/node_modules` and adds it to Mash's own
`settings.json`: pi installs user packages under its agent directory, which Mash
points at `~/.mash/pi/agent`, never at the signed bundle and never at the user's
own `$HOME/.pi/agent`. Downloads cache under `~/.mash/cache/npm`. Packages Mash ships
for everyone live in the bundle and are added through the build instead.

For the full map — every config path, how to author an extension or skill, how
to install a package, which machine tools Mash borrows, and what must go through
the repository instead — load the `mash-customize` skill.
EOF
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
  local py="$(mash_res)/python/bin/python3"
  "$py" - "$@" <<'PY'
import os, sys
repls = (
    (b"~/.config/mash", b"~/.mash/config/mash"),
    (b"~/.pi/agent", b"~/.mash/pi/agent"),
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
  cat >"$pi/scripts/ensure-hindsight-daemon.sh" <<'MASH_HINDSIGHT'
#!/bin/bash
# Hindsight warm-start: start the embed daemon when Mash has installed it.
# Fail open. A missing tool, a held port, or a cold boot must never block a
# session.
#
# Hindsight resolves all of its state through Path.home(), so every hindsight
# command below runs with HOME set to Mash's data folder. That is what keeps
# ~/.hindsight and ~/.pg0 inside ~/.mash instead of the real home, and it is
# also what makes the daemon inherit the same tree: it is spawned with
# os.environ.copy(). Nothing outside this script sees a changed HOME.
exec 0</dev/null

data="${MASH_DATA_DIR:-}"
if [ -z "$data" ] && [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
  data="$(cd "$PI_CODING_AGENT_DIR/../.." 2>/dev/null && pwd)"
fi
[ -n "$data" ] && [ -d "$data" ] || exit 0
export HOME="$data"
# HF_HOME is not implied by HOME. HuggingFace resolves its cache from
# $HOME/.cache/huggingface unless this is set. The daemon otherwise writes a
# second copy of the model outside Mash's cache; pin it to the cache directory
# the wizard and lib.sh both use. This warm-start runs outside both.
HF_HOME="$HOME/cache/huggingface"
HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export HF_HOME HUGGINGFACE_HUB_CACHE
# Same for the reranker. flashrank falls back to /tmp when this is unset, and
# lib.sh sets it for every pane -- but this warm-start runs outside lib.sh.
HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR="$HOME/cache/flashrank"
export HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR
PATH="${HOME}/.local/bin:${PATH}"
export PATH
# Mash's own shim, by absolute path on purpose. The inherited PATH still holds
# the owner's ~/.local/bin, so a bare `command -v hindsight-embed` would find
# their 1.8 GB install and run it against Mash's data folder.
EMBED="${HOME}/.local/bin/hindsight-embed"

HOOK_LOG="${HOME}/.hindsight/hook-last-run.log"
HOOK_LOG_MAX="${HINDSIGHT_HOOK_LOG_MAX:-1048576}"
DAEMON_LOG="${HOME}/.hindsight/daemon.log"
DAEMON_LOG_MAX="${HINDSIGHT_DAEMON_LOG_MAX:-33554432}"

hook_log() {
  mkdir -p "${HOME}/.hindsight"
  if [ -f "$HOOK_LOG" ] && [ "$(wc -c <"$HOOK_LOG")" -ge "$HOOK_LOG_MAX" ]; then
    mv -f "$HOOK_LOG" "${HOOK_LOG}.1"
  fi
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >>"$HOOK_LOG"
}

read_pin() {
  local f="${MASH_CONFIG_DIR:-${HOME}/config/mash}/hindsight-pin"
  if [ -f "$f" ]; then
    tr -d '[:space:]' <"$f"
  else
    echo unknown
  fi
}

# Masked to four digits, because the config never carries the port on its own.
daemon_port() {
  local cfg port=""
  for cfg in "${HOME}/.hindsight/embed" "${HOME}/.hindsight/config.env"; do
    [ -f "$cfg" ] || continue
    port="$(sed -n 's/^HINDSIGHT_API_PORT=\([0-9][0-9]*\).*/\1/p' "$cfg" | tail -1)"
    [ -n "$port" ] && break
  done
  printf '%s' "${port:-8998}"
}

# `daemon status` is a bare GET /health, so any service squatting on the port
# looks healthy. Require the /version fingerprint instead.
daemon_healthy() {
  if ! command -v curl >/dev/null 2>&1; then
    "$EMBED" daemon status >/dev/null 2>&1
    return $?
  fi
  curl -fsS -m 2 "http://127.0.0.1:$(daemon_port)/version" 2>/dev/null |
    grep -q '"api_version"'
}

pin="$(read_pin)"

[ -f "${HOME}/.hindsight/embed" ] || [ -f "${HOME}/.hindsight/config.env" ] || exit 0

if [ ! -x "$EMBED" ]; then
  hook_log "hindsight-embed is not installed (pin ${pin}); the first launch installs it"
  exit 0
fi

if daemon_healthy; then
  exit 0
fi

if "$EMBED" daemon status >/dev/null 2>&1; then
  hook_log "port $(daemon_port) answers /health but is not Hindsight; not started (pin ${pin})"
  exit 0
fi

# The daemon is not running, so its log is safe to rotate before it reopens it.
if [ -f "$DAEMON_LOG" ] && [ "$(wc -c <"$DAEMON_LOG")" -ge "$DAEMON_LOG_MAX" ]; then
  mv -f "$DAEMON_LOG" "${DAEMON_LOG}.1"
fi

if HINDSIGHT_EMBED_DAEMON_STARTUP_TIMEOUT="${HINDSIGHT_EMBED_DAEMON_STARTUP_TIMEOUT:-600}" \
  "$EMBED" daemon start >>"$HOOK_LOG" 2>&1; then
  hook_log "daemon started (pin ${pin}, port $(daemon_port))"
else
  hook_log "daemon start failed (pin ${pin}); see ~/.hindsight/daemon.log"
fi

exit 0
MASH_HINDSIGHT
  chmod 755 "$pi/scripts/ensure-hindsight-daemon.sh"
  cat >"$pi/mcp.json" <<'EOF'
{
  "mcpServers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp"
    },
    "sentrux": {
      "command": "sentrux",
      "args": [
        "mcp"
      ]
    },
    "cua-driver": {
      "command": "cua-driver",
      "args": [
        "mcp"
      ]
    },
    "agent-browser": {
      "command": "agent-browser",
      "args": [
        "mcp",
        "--tools",
        "core,network,debug"
      ]
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

# Seeded to ~/.mash/.hindsight/embed on first launch. Never carries a secret:
# the provider is `none`, so retain and recall work and only `reflect` needs a
# real key, which the owner can add in place.
mash_write_hindsight_config() {
  cat >"$1/hindsight-embed.env" <<'EOF'
# Hindsight Embed Configuration
# Seeded by Mash. `hindsight-embed configure` rewrites this file in place.

HINDSIGHT_EMBED_BANK_ID=default
HINDSIGHT_EMBED_DAEMON_IDLE_TIMEOUT=0

# Retain and recall work with no LLM at all; only `reflect` needs one. Keeping
# the provider at `none` means no key has to leave this app.
HINDSIGHT_API_LLM_PROVIDER=none
# The wrapper refuses to run when the key is unset, even for provider `none`.
HINDSIGHT_API_LLM_API_KEY=unused

# Both default to `local`, which means sentence-transformers, which is not
# installed: Mash uses hindsight-api-slim with [embedded-db,local-onnx], and
# the full package would pull torch and MLX (1.8 GB instead of 0.9 GB). Without
# these two lines the daemon boots and then dies with
# "sentence-transformers is required for LocalSTEmbeddings".
#
# onnx and flashrank are exactly what local-onnx provides: onnxruntime loads
# intfloat/multilingual-e5-small, and flashrank loads its own cross-encoder.
HINDSIGHT_API_EMBEDDINGS_PROVIDER=onnx
HINDSIGHT_API_RERANKER_PROVIDER=flashrank

# Mash's own ports. The owner's own Hindsight holds 8888/8898, and its embedded
# Postgres holds 15432, so neither can be reused here.
HINDSIGHT_API_PORT=8998
HINDSIGHT_EMBED_API_DATABASE_URL=pg0://mash-hindsight:15442
EOF
}

mash_build_parallel_venv() {
  local dest="$1"
  local py="$(mash_res)/python/bin/python3"
  local req cache home_dir cleanup=""
  req="$(mash_skills_src)/src/skills/mash-parallel/requirements.txt"
  [ -f "$req" ] || {
    echo "missing mash-parallel requirements.txt" >&2
    exit 1
  }
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

# After the staged app moves, point every venv at the finished bundle path.
mash_finish_skill_venv() {
  local dest="$1"
  local old="${2:-}"
  local venvs="$dest/Contents/Resources/defaults/mash-config/venvs"
  local py="$dest/Contents/Resources/python/bin/python3"
  local venv name
  [ -d "$venvs" ] || return 0
  [ -x "$py" ] || {
    echo "bundled Python is missing" >&2
    exit 1
  }
  for venv in "$venvs"/*; do
    [ -d "$venv" ] || continue
    name="$(basename "$venv")"
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
    # Relative on purpose: an absolute link here points outside the bundle once
    # it is copied into a disk image, and codesign rejects a bundle whose
    # symlink escapes it. The launcher re-points this at ~/.mash on first run.
    local pyrel
    pyrel="$("$py" -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
      "$py" "$venv/bin")"
    ln -sfn "$pyrel" "$venv/bin/python"
    ln -sfn python "$venv/bin/python3"
    if [ -L "$venv/bin/python3.13" ]; then
      ln -sfn python "$venv/bin/python3.13"
    fi
    case "$name" in
    mash-parallel) "$venv/bin/python" -c 'import pytest' ;;
    *) "$venv/bin/python" -c 'import sys' ;;
    esac
  done
}

# --- design stack ---------------------------------------------------------
#
# A second toolkit, installed the way the first one is: copy the payload, build
# the dependencies, never run its installer. That installer also writes
# ~/.cursor/mcp.json and a manifest, and Mash ships neither.
mash_require_design_skills() {
  local src ver
  src="$(mash_design_src)"
  if [ ! -f "$src/VERSION" ]; then
    echo "Design skills checkout is missing at $src." >&2
    echo "Set MASH_DESIGN_SRC to a checkout of the pinned release." >&2
    exit 1
  fi
  ver="$(tr -d '[:space:]' <"$src/VERSION")"
  if [ "$ver" != "0.1.1" ]; then
    echo "Design skills VERSION is $ver, want 0.1.1." >&2
    exit 1
  fi
}

# Overridable so CI can point at its own clone, the way MASH_SKILLS_SRC is.
# Without this the path is pinned to a maintainer's home, which no runner has.
mash_design_src() { printf '%s\n' "${MASH_DESIGN_SRC:-$home/Development/mash-design-skills}"; }

# npm from the staged bundle, never the host's. HOME and the npm cache stay in
# the build workdir so nothing is written to the user's account.
mash_bundled_npm() {
  local home_dir cache_dir
  if [ -n "${work:-}" ]; then
    home_dir="$work/home"
    cache_dir="$work/npm-cache"
  else
    home_dir="$(mktemp -d "$root/dist/.design-npm.XXXXXX")"
    cache_dir="$home_dir/cache"
  fi
  mkdir -p "$home_dir" "$cache_dir"
  env HOME="$home_dir" npm_config_cache="$cache_dir" npm_config_update_notifier=false \
    "$(mash_res)/node/bin/npm" "$@"
}

# The penpot-local MCP server. Built at build time because it needs tsc; the
# launcher only ever starts the compiled server.
mash_build_design_headless() {
  local src="$1" dest="$2"
  local node_runtime="$(mash_res)/node/bin/node"
  [ -d "$src" ] || {
    echo "design headless source is missing" >&2
    exit 1
  }
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -C "$src" --exclude node_modules --exclude dist --exclude .git -cf - . |
    tar -C "$dest" -xf -
  mash_bundled_npm install --prefix "$dest"
  (cd "$dest" && mash_bundled_npm run build) || {
    echo "headless build failed" >&2
    exit 1
  }
  [ -f "$dest/dist/server.js" ] || {
    echo "headless server.js was not produced" >&2
    exit 1
  }
  # The build needs tsc and vitest and the bundler trees behind them; the
  # server does not. `npm run build` is a plain `tsc`, and every runtime import
  # in dist/ is either relative or one of the three packages under
  # `dependencies`. Dropping devDependencies takes this tree from 108 MB to
  # 27 MB and leaves the server's module graph intact.
  mash_bundled_npm prune --omit=dev --prefix "$dest"
  # Prove the pruned tree still loads before the app is signed. This is a stdio
  # server, so it is given its own deadline: a check that waits on stdin would
  # hang the build instead of reporting anything.
  "$node_runtime" -e "
    const guard = setTimeout(() => {
      console.error('headless load check timed out');
      process.exit(1);
    }, 20000);
    const p = '$dest/dist/server.js';
    import(require('node:url').pathToFileURL(p).href).catch((e) => {
      // A missing PENPOT_* configuration is expected: this only proves the
      // module graph resolved. Anything else is a real packaging fault.
      if (!/penpot-local configuration/.test(String(e && e.message))) {
        clearTimeout(guard);
        console.error('headless server failed to load: ' + e);
        process.exit(1);
      }
    }).then(() => {
      clearTimeout(guard);
      process.exit(0);
    });
  " || {
    echo "the pruned headless server no longer loads" >&2
    exit 1
  }
}

mash_install_design_skills() {
  local src pi cfg stack name skill
  mash_require_design_skills
  src="$(mash_design_src)"
  pi="$(mash_res)/defaults/pi"
  cfg="$(mash_res)/defaults/mash-config"
  stack="$(mash_res)/defaults/design-stack"
  case "$pi" in
  "$(mash_res)/defaults/pi") ;;
  *)
    echo "refusing to install design skills outside the staged app" >&2
    exit 1
    ;;
  esac
  mkdir -p "$pi/skills" "$pi/agents" "$cfg/node_modules" "$cfg/venvs" "$stack"

  tar -C "$src/src/agents" --exclude '.git' -cf - . | tar -C "$pi/agents" -xf -

  for name in "$src/src/skills"/*; do
    [ -d "$name" ] || continue
    skill="$(basename "$name")"
    rm -rf "$pi/skills/$skill"
    mkdir -p "$pi/skills/$skill"
    tar -C "$name" \
      --exclude '.venv' --exclude 'node_modules' --exclude '__pycache__' \
      --exclude '.pytest_cache' --exclude '.git' --exclude 'target' \
      -cf - . | tar -C "$pi/skills/$skill" -xf -
    # The design stack's Python and npm dependencies are deliberately NOT built
    # here. They are about 175 MB, and they are useless until `mds setup` has
    # run — which itself needs Docker and network. `mds` calls mash-design-deps,
    # which installs them into the data folder on demand.
    #
    # The headless MCP server below is the exception: it is small once its
    # devDependencies are pruned, and the penpot-local entry needs it as soon as
    # setup finishes, so it ships.
  done

  mash_build_design_headless "$src/headless" "$cfg/headless"

  for name in bin lib docker docker-compose.yaml convert.sh .env.example \
    penpot.env.example NOTICE LICENSE README.md; do
    [ -e "$src/$name" ] || continue
    tar -C "$src" --exclude '.git' --exclude node_modules -cf - "$name" |
      tar -C "$stack" -xf -
  done
  # Patch only the staged copy; the pinned toolkit checkout stays read-only.
  "$(mash_res)/python/bin/python3" \
    "$root/packaging/patch-design-pi.py" "$stack" "$src"
  # `mds setup` generates the real one, with PENPOT_SECRET_KEY and OD_API_TOKEN
  # inside. The toolkit checkout may carry one; it must never ship.
  rm -f "$stack/penpot.env"

  # Same rewrite the first toolkit gets, so the design skills' ~/.config/mash
  # references land in the data folder too.
  mash_rewrite_skill_paths "$pi"

  [ -f "$pi/skills/mash-design-setup/SKILL.md" ] || {
    echo "mash-design-setup was not staged" >&2
    exit 1
  }
  [ -f "$stack/bin/mds" ] || {
    echo "the design stack CLI was not staged" >&2
    exit 1
  }
  [ -f "$stack/docker-compose.yaml" ] || {
    echo "the design compose file was not staged" >&2
    exit 1
  }
  [ -f "$cfg/headless/dist/server.js" ] || {
    echo "the headless Penpot server was not built" >&2
    exit 1
  }
  if [ -f "$stack/penpot.env" ]; then
    echo "the design stack must not carry penpot.env" >&2
    exit 1
  fi
}

mash_write_pins() {
  if [ ! -f "$root/packaging/pins.txt" ]; then
    mash_pins_text >"$root/packaging/pins.txt"
  fi
}
