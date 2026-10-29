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
  mash_download "$URL" "$SHA256" "$tmp/archive" || {
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
  mash_download "$URL" "$SHA256" "$tmp/archive" || {
    echo "could not download $component $VERSION for $target" >&2
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
  for name in cache-hit dev-tab fingers fork-from-message mash-orchestration pr-watch-focus herdr-workspace telescope mash-update-notice; do
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
  for name in fresh-config-dir fresh-reveal-in-finder fresh-warn-logs; do
    [ -f "$root/packaging/patches/$name.patch" ] || {
      echo "missing Fresh patch $name" >&2
      exit 1
    }
  done
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
# Fail the build when a Ghostty feature Mash deliberately removes comes back.
#
# Mash Terminal is a host for one full-window Herdr client: Ghostty's own tabs,
# splits, command palette, find bar, quick terminal and inspector would draw a
# second surface on top of Herdr. They are rejected in the fork's shared action
# layer and deleted from the macOS menus, so a rebase that reintroduces one is
# a silent regression unless something says so. This is that something: it runs
# before the build, names the offending file, and costs one grep.
#
# The GTK template and action-map checks below also catch shortcuts and
# direct GTK actions that would bypass the removed menu items.
#
#   mash_ghostty_trim_check <ghostty-src>
mash_ghostty_trim_check() {
  local src="$1" status=0 item
  [ -d "$src" ] || {
    echo "cannot check the Ghostty fork: $src is missing" >&2
    return 1
  }

  # The shared rejection, which is what covers both platforms.
  grep -q 'mash_removed_ui' "$src/src/Surface.zig" 2>/dev/null || {
    echo "Ghostty fork lost the shared action rejection in src/Surface.zig" >&2
    echo "Mash ships no Ghostty tabs, splits, palette, search, quick terminal or inspector." >&2
    status=1
  }

  # The macOS menu items, by title. Deleting the item is the point: a
  # disabled one still reads as a feature Mash offers.
  for item in "New Tab" "Close Tab" "Split Right" "Split Left" "Split Down" \
    "Split Up" "Command Palette" "Quick Terminal" "Terminal Inspector" \
    "Zoom Split" "Equalize Splits" "Resize Split" "Change Tab Title..."; do
    if grep -qF "title=\"$item\"" "$src/macos/Sources/App/MainMenu.xib" 2>/dev/null; then
      echo "Ghostty fork reintroduced the macOS menu item '$item'" >&2
      status=1
    fi
  done

  # New Window is the opposite check: it opens a second Mash instance, so its
  # disappearance breaks that flow silently.
  grep -qF 'title="New Window"' "$src/macos/Sources/App/MainMenu.xib" 2>/dev/null || {
    echo "Ghostty fork lost the macOS 'New Window' menu item" >&2
    status=1
  }

  # The GTK menus and buttons, which are a different frontend from the macOS
  # xib. window.blp owns the titlebar and main menu, surface.blp the terminal
  # context menu; both must stay free of the removed features, and the tab bar
  # itself has to be gone rather than merely hidden.
  local gtk_window="$src/src/apprt/gtk/ui/1.5/window.blp"
  local gtk_surface="$src/src/apprt/gtk/ui/1.2/surface.blp"
  for needle in 'menu split_menu' 'Adw.TabBar tab_bar' 'action: "win.new-tab"' \
    'action: "win.toggle-command-palette"' 'action: "win.toggle-inspector"' \
    'action: "win.split-' 'clicked => $new_tab()' \
    'tooltip-text: _("View Open Tabs")'; do
    if grep -qF "$needle" "$gtk_window" 2>/dev/null; then
      echo "Ghostty fork reintroduced '$needle' in the GTK window" >&2
      status=1
    fi
  done
  for needle in 'action: "split-tree.new-split"' 'action: "win.new-tab"' \
    'label: _("Close Split")' 'label: _("Tab")'; do
    if grep -qF "$needle" "$gtk_surface" 2>/dev/null; then
      echo "Ghostty fork reintroduced '$needle' in the GTK context menu" >&2
      status=1
    fi
  done
  # Menu deletion alone leaves these registered as directly invokable GTK
  # actions (notably app.new-tab and app.toggle-quick-terminal via DBus).
  for name in new-tab split-right split-left split-up split-down \
    toggle-command-palette toggle-inspector; do
    if grep -qF ".init(\"$name\", " "$src/src/apprt/gtk/class/window.zig" 2>/dev/null; then
      echo "Ghostty fork still registers the GTK window action '$name'" >&2
      status=1
    fi
  done
  for name in new-tab toggle-quick-terminal; do
    if grep -qF ".init(\"$name\", " "$src/src/apprt/gtk/class/application.zig" 2>/dev/null; then
      echo "Ghostty fork still registers the GTK application action '$name'" >&2
      status=1
    fi
  done
  # The page and split-tree widgets expose direct GTK actions too: unlike
  # keyboard bindings, these bypass Surface.performBindingAction entirely.
  for name in new-split equalize zoom close-split; do
    if grep -qF ".init(\"$name\", " "$src/src/apprt/gtk/class/split_tree.zig" 2>/dev/null; then
      echo "Ghostty fork still registers the GTK split-tree action '$name'" >&2
      status=1
    fi
  done
  for name in close next-page previous-page prompt-tab-title; do
    if grep -qF ".init(\"$name\", " "$src/src/apprt/gtk/class/tab.zig" 2>/dev/null; then
      echo "Ghostty fork still registers the GTK tab action '$name'" >&2
      status=1
    fi
  done
  if grep -qF '"tab.next-page"' "$src/src/apprt/gtk/class/surface.zig" 2>/dev/null; then
    echo "Ghostty fork still diverts horizontal scrolling to GTK tabs" >&2
    status=1
  fi

  # New Window must survive on Linux too: it is the second-instance entry point
  # the desktop file and the macOS Dock menu both rely on.
  grep -qF 'action: "win.new-window"' "$gtk_window" 2>/dev/null || {
    echo "Ghostty fork lost the GTK 'New Window' menu item" >&2
    status=1
  }

  # A template child that Zig still requires but the blueprint no longer
  # declares panics the moment the window is instantiated, and a blueprint-only
  # check cannot see it. Removing the tab bar from window.blp is what makes
  # this pairing worth asserting.
  if ! grep -qF 'Adw.TabBar' "$gtk_window" 2>/dev/null; then
    if grep -qF 'bindTemplateChildPrivate("tab_bar"' "$src/src/apprt/gtk/class/window.zig" 2>/dev/null; then
      echo "Ghostty fork still binds the 'tab_bar' template child that window.blp no longer declares" >&2
      status=1
    fi
    if grep -qF 'priv.tab_bar' "$src/src/apprt/gtk/class/window.zig" 2>/dev/null; then
      echo "Ghostty fork still uses priv.tab_bar after the tab bar was removed" >&2
      status=1
    fi
  fi

  # Scripting and Finder services are entry points a menu grep cannot see.
  if grep -qE '<command name="(new tab|split)"' "$src/macos/Ghostty.sdef" 2>/dev/null; then
    echo "Ghostty fork reintroduced the AppleScript tab/split commands" >&2
    status=1
  fi
  if grep -q '<string>openTab</string>' "$src/macos/Ghostty-Info.plist" 2>/dev/null; then
    echo "Ghostty fork reintroduced the 'New Tab Here' Finder service" >&2
    status=1
  fi

  # Second pass: menu items that do not fit a Herdr host, and the code that the
  # first pass left compiled behind its rejected actions.
  local xib="$src/macos/Sources/App/MainMenu.xib"
  for item in "Make Ghostty the Default Terminal" "Check for Updates..." \
    "Undo" "Redo" "Change Terminal Title..." "Float on Top" \
    "Use as Default" "Ghostty Help" "About Ghostty" "Hide Ghostty" \
    "Quit Ghostty"; do
    if grep -qF "title=\"$item\"" "$xib" 2>/dev/null; then
      echo "Ghostty fork reintroduced the macOS menu item '$item'" >&2
      status=1
    fi
  done
  # Items Mash keeps, including the renamed app-menu entries.
  for item in "About Mash" "Hide Mash" "Quit Mash" "Close Window" "Copy" \
    "Paste" "Show/Hide All Terminals" "Terminal Read-only"; do
    grep -qF "title=\"$item\"" "$xib" 2>/dev/null || {
      echo "Ghostty fork lost the macOS menu item '$item'" >&2
      status=1
    }
  done
  # The terminal right-click menu is built in Swift, not the xib.
  local surface_view="$src/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift"
  for item in "Split Right" "Split Left" "Split Down" "Split Up" \
    "Toggle Terminal Inspector" "Change Tab Title..." "Change Terminal Title..."; do
    if grep -qF "withTitle: \"$item\"" "$surface_view" 2>/dev/null; then
      echo "Ghostty fork reintroduced '$item' in the macOS terminal context menu" >&2
      status=1
    fi
  done
  if grep -qF 'title: "Rename Tab..."' \
    "$src/macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift" 2>/dev/null; then
    echo "Ghostty fork reintroduced the macOS 'Rename Tab...' tab menu item" >&2
    status=1
  fi
  for path in "macos/Sources/Features/QuickTerminal" \
    "macos/Sources/Features/Command Palette" "macos/Sources/Features/Update" \
    "macos/Sources/Features/App Intents/QuickTerminalIntent.swift" \
    "macos/Sources/Features/App Intents/CommandPaletteIntent.swift" \
    "macos/Sources/Ghostty/Surface View/InspectorView.swift" \
    "src/apprt/gtk/class/command_palette.zig" \
    "src/apprt/gtk/class/inspector_widget.zig" \
    "src/apprt/gtk/class/inspector_window.zig" \
    "src/apprt/gtk/class/imgui_widget.zig" \
    "src/apprt/gtk/class/search_overlay.zig" \
    "src/apprt/gtk/class/title_dialog.zig" \
    "src/cli/toggle_quick_terminal.zig"; do
    if [ -e "$src/$path" ]; then
      echo "Ghostty fork still ships $path" >&2
      status=1
    fi
  done
  if grep -qi 'sparkle' "$src/macos/Ghostty.xcodeproj/project.pbxproj" 2>/dev/null; then
    echo "Ghostty fork still links the Sparkle updater" >&2
    status=1
  fi
  if grep -q '<key>SU' "$src/macos/Ghostty-Info.plist" 2>/dev/null; then
    echo "Ghostty fork still carries Sparkle keys in Info.plist" >&2
    status=1
  fi
  # The undo registrations stay in tab and window code; a zero expiry is what
  # turns every one of them into a no-op, so a closed window frees its instance.
  grep -qF 'mash: no Ghostty undo' \
    "$src/macos/Sources/Features/Terminal/BaseTerminalController.swift" 2>/dev/null || {
    echo "Ghostty fork re-enabled undo of closed windows" >&2
    status=1
  }
  for name in undo redo check_for_updates toggle_window_float_on_top \
    prompt_surface_title prompt_tab_title prompt_window_title set_surface_title; do
    awk '/^(pub )?const mash_removed_ui/,/^}\);/' "$src/src/Surface.zig" 2>/dev/null |
      grep -qE "^[[:space:]]*\.$name," || {
      echo "Ghostty fork no longer rejects the '$name' action" >&2
      status=1
    }
  done
  for needle in 'win.prompt-surface-title' 'win.prompt-window-title' \
    'label: _("About Ghostty")'; do
    if grep -qF "$needle" "$gtk_window" "$gtk_surface" 2>/dev/null; then
      echo "Ghostty fork reintroduced '$needle' in the GTK menus" >&2
      status=1
    fi
  done
  grep -qF 'label: _("About Mash Terminal")' "$gtk_window" 2>/dev/null || {
    echo "Ghostty fork lost the GTK 'About Mash Terminal' menu item" >&2
    status=1
  }

  # Mash's own menus: every item invokes a Herdr command by sending its chord
  # through mash_send_key. Losing the action or either menu table drops the
  # whole menu set on that platform.
  grep -qE '^    mash_send_key: \[\]const u8,' "$src/src/input/Binding.zig" 2>/dev/null || {
    echo "Ghostty fork lost the mash_send_key action Mash's menus depend on" >&2
    status=1
  }
  grep -qF 'MashMenus.install' "$src/macos/Sources/App/AppDelegate.swift" 2>/dev/null &&
    [ -f "$src/macos/Sources/App/MashMenus.swift" ] || {
    echo "Ghostty fork lost Mash's macOS menu items" >&2
    status=1
  }
  grep -qF 'action: "win.mash-send-key"' "$gtk_window" 2>/dev/null &&
    grep -qF '.init("mash-send-key", ' "$src/src/apprt/gtk/class/window.zig" 2>/dev/null || {
    echo "Ghostty fork lost Mash's GTK menu items" >&2
    status=1
  }
  # Presence is not enough: an item whose chord no longer matches the shipped
  # Herdr config opens a menu, sends a keystroke nothing binds, and fails
  # silently. Compare both menu tables against both configs.
  local packaging
  packaging="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "${MASH_PYTHON:-python3}" "$packaging/menu-chords.py" "$src" "$packaging" ||
    status=1

  return "$status"
}

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
  for name in fresh-config-dir fresh-reveal-in-finder fresh-warn-logs; do
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
# Production logs default to warnings. RUST_LOG=debug remains an opt-in for
# diagnosing a particular Fresh launch.
export RUST_LOG="${RUST_LOG:-warn}"
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
  for name in cache-hit dev-tab fingers fork-from-message mash-orchestration \
    image-popup pr-watch-focus; do
    mash_copy_tree "$src/$name" "$plugins/$name"
  done
  # Both platforms use one popup plugin: Linux's notice pane is read-only;
  # macOS's update pane downloads a verified release before installation.
  mash_copy_tree "$src/mash-update-notice" "$plugins/mash-update-notice"

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

  # The notifier is a macOS .app helper. Linux gets its notifications through
  # Herdr and the terminal instead, so the plugin is not staged there -- and the
  # plist and codesign steps below are Apple-only regardless.
  if [ "$(uname -s)" = "Darwin" ]; then
    git clone --depth 1 https://github.com/dot/herdr-terminal-notifier.git "$work/src/notifier"
    mash_copy_tree "$work/src/notifier" "$plugins/dot.terminal-notifier"
    local notifier="$plugins/dot.terminal-notifier/assets/HerdrNotify.app"
    local plist="$notifier/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.mash.notifications' "$plist"
    # Notification Center draws the alert's name and icon from the bundle that
    # posted it, which upstream ships as "herdr" with Ghostty's Terminal.icns.
    # Mash posts these, so they carry Mash's name and artwork instead.
    # Do not reuse app.mash.notify: Notification Center caches its old herdr identity.
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName Mash' "$plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Mash' "$plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile Mash' "$plist"
    cp "$root/packaging/Mash.icns" "$notifier/Contents/Resources/Mash.icns"
    rm -f "$notifier/Contents/Resources/Terminal.icns"
    codesign --force --deep --sign - "$notifier"
  fi

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

# One required sentence in a shipped file, or the build stops with its reason.
# The gates inside mash_install_skills all share this shape; naming the sentence
# in the message is what makes a drift a one-line fix instead of a bisect.
mash_require_text() {
  grep -q -- "$2" "$1" || {
    echo "$3" >&2
    exit 1
  }
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
  mash_require_text "$pi/APPEND_SYSTEM.md" 'mash-customize' \
    "APPEND_SYSTEM.md does not point at mash-customize"
  mash_require_text "$pi/APPEND_SYSTEM.md" '^## Tool-call recovery$' \
    "APPEND_SYSTEM.md is missing tool-call recovery guidance"
  mash_require_text "$pi/APPEND_SYSTEM.md" 'Never include both' \
    "APPEND_SYSTEM.md is missing ask_user argument guidance"
  mash_require_text "$pi/APPEND_SYSTEM.md" 'uv_cwd' \
    "APPEND_SYSTEM.md is missing codemode cwd guidance"
  mash_require_text "$pi/APPEND_SYSTEM.md" '^## Review a finished session$' \
    "APPEND_SYSTEM.md is missing the review-tab suggestion"
  mash_require_text "$pi/APPEND_SYSTEM.md" 'HOME. is not changed' \
    "APPEND_SYSTEM.md is missing the Mash environment section"
  # The rewrite pass must not have touched the sentence that names the user's
  # own Pi, or it would read as Mash's own directory.
  mash_require_text "$pi/APPEND_SYSTEM.md" '\$HOME/\.pi/agent' \
    "APPEND_SYSTEM.md lost the distinction between Mash's Pi and the user's"
  # The guidance ships to every user, so it must not name the machine that
  # built it: a checkout path or a home directory is meaningless anywhere else
  # and points the agent at a directory that does not exist. Checked on the
  # staged tree so the build's own rewrite pass is covered too.
  if grep -rlE '/Volumes/|/Users/' "$pi/APPEND_SYSTEM.md" "$pi/AGENTS.md" \
    "$pi/skills/mash-customize" >/dev/null 2>&1; then
    echo "Mash's pi guidance names a path on the build machine" >&2
    exit 1
  fi
  # Hindsight commands in the skills must reach Mash's daemon: nothing may put
  # the owner's ~/.local/bin ahead of Mash's wrapper or read the owner's
  # ~/.hindsight/embed. See the rewrites in mash_rewrite_skill_paths.
  if grep -rlE '\$\{?HOME\}?/\.local/bin|~/\.local/bin|\$\{?HOME\}?/\.hindsight/' \
    "$pi/skills" "$pi/agents" "$pi/APPEND_SYSTEM.md" 2>/dev/null |
    grep -v '/mash-customize/' | grep -q .; then
    echo "a skill still routes hindsight-embed to the owner's Hindsight" >&2
    exit 1
  fi
  # Sentrux resolves a relative path against the MCP server's own working
  # directory, so a skill that still teaches `.` silently scans the wrong tree.
  if [ -f "$pi/skills/mash-sentrux/SKILL.md" ]; then
    if grep -qE 'run relative to the workspace root|typically `"\."`' \
      "$pi/skills/mash-sentrux/SKILL.md"; then
      echo "mash-sentrux still tells agents to pass a relative scan path" >&2
      exit 1
    fi
    mash_require_text "$pi/skills/mash-sentrux/SKILL.md" 'absolute path' \
      "mash-sentrux does not require an absolute Sentrux scan path"
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
  # GitHub's MCP is added per user by mash-github-mcp after sign-in, never
  # shipped. What must never ship is a credential, so look for the token
  # shapes themselves rather than the word "github".
  if grep -qE 'gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' "$pi/mcp.json"; then
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

  # Runtime copies only the programming suite into ~/.mash. Keep the inventory
  # beside the staged defaults so launchers and ownership sync agree, even if
  # a future pinned release adds a skill or agent with a new name.
  {
    printf '%s\n' AGENTS.md APPEND_SYSTEM.md \
      extensions/mash-hindsight-daemon.ts scripts/ensure-hindsight-daemon.sh
    for name in "$(mash_skills_src)/src/skills"/*; do
      [ -d "$name" ] && printf 'skills/%s\n' "$(basename "$name")"
    done
    for name in "$(mash_skills_src)/src/agents"/*; do
      [ -f "$name" ] && printf 'agents/%s\n' "$(basename "$name")"
    done
  } >"$(mash_res)/defaults/optional-programming.txt"
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
  local src="$1" dest="$2" mdc name description review_chord
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
    # The review-tab chord is the one platform difference in this guidance, and
    # it is the point of the suggestion, so it is printed here rather than
    # written into the quoted heredocs around it.
    if [ "$(uname -s)" = "Darwin" ]; then
      review_chord='⌘⇧R'
    else
      review_chord='Ctrl+Shift+R'
    fi
    printf '## Review a finished session\n\nWhen a session changes two or more files, close it by suggesting the user\nopen a review tab (`%s`): the tab pairs the session diff with an agent, so the\nwork gets read instead of trusted. One short line, once per session. Skip it\nfor a single-file or trivial edit.\n\n' "$review_chord"
    cat <<'EOF'
## Tool-call recovery

- For `ask_user`, use exactly one form: `question` for one question, or
  `questions` for a batch of 2–4 independent questions. Never include both.
  With `questions`, put `context`, `options`, `allowMultiple` and
  `allowFreeform` on each entry, never at the top level.
  On validation error, correct the payload; never retry it unchanged.
- If `codemode` fails before script execution with `uv_cwd`, `process.cwd`, or
  a missing-working-directory error, treat it as a session/environment failure,
  not a script bug. Do not retry `codemode` or try to fix cwd inside its script.
  Use direct tools only if they work (prefer absolute paths); if needed tools
  also fail, stop and report the cwd blocker.
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
    # Mash never changes HOME, so the skills' own spelling of Hindsight's home
    # is the owner's: ${HOME}/.hindsight/embed is the owner's config and port,
    # and prepending ${HOME}/.local/bin puts the owner's hindsight-embed ahead
    # of Mash's wrapper on MASH_BIN. The wrapper (helpers/hindsight-embed) runs
    # Mash's install with HOME pointed at the data folder, so every command
    # reaches Mash's daemon on 8998 and not the owner's.
    (b'export PATH="${HOME}/.local/bin:${PATH}"\n', b""),
    (b'"${HOME}/.hindsight/embed"', b'"${MASH_DATA_DIR:-$HOME/.mash}/.hindsight/embed"'),
    (b'port="${port:-8888}"', b'port="${port:-8998}"'),
    (b" (prepend `~/.local/bin` to PATH)", b""),
    (b"; PATH includes `${HOME}/.local/bin`", b""),
    # Sentrux's MCP server is one long-lived process with its own working
    # directory, so a relative path is resolved against that, not against the
    # pane or the repository under discussion. When the server happens to start
    # in the repository the two agree and the advice looks correct; started
    # anywhere else, `scan {path: "."}` silently reports a different tree --
    # 4448 files of /tmp, or 100000 files for `/` -- with no error, and those
    # numbers reach topology.json and the plan's architecture baseline.
    # Absolute paths are the only safe instruction.
    (
        b"All Sentrux commands run relative to the workspace root directory (e.g., `.`).",
        b"Pass the workspace root as an **absolute path** to every Sentrux MCP tool\n"
        b"(resolve it once with `git rev-parse --show-toplevel`). The MCP server is a\n"
        b"long-lived process with its own working directory, so a relative path such as\n"
        b"`.` is resolved against that directory and silently scans the wrong tree.",
    ),
    (
        b'Use one key for the actual scan root (typically `"."`).',
        b"Key the map by the same absolute workspace-root path passed to the tools.",
    ),
    (b'# From the workspace root (.), not a subdirectory such as src/.',
     b"# From the workspace root, named absolutely, not a subdirectory such as src/."),
    (b"sentrux gate --save .", b'sentrux gate --save "$(git rev-parse --show-toplevel)"'),
    (b"sentrux gate .", b'sentrux gate "$(git rev-parse --show-toplevel)"'),
    # The schema examples are what an agent copies when it writes the artifact,
    # so they have to show an absolute key too.
    (b'    ".": {', b'    "/abs/path/to/workspace": {'),
    (b'  ".": "started"', b'  "/abs/path/to/workspace": "started"'),
    (b"| . | pass (6772", b"| /abs/path/to/workspace | pass (6772"),
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
# Point every staged venv at the root it will actually run from, and make its
# interpreter link relative so the tree survives being copied or packaged.
#
#   mash_finish_skill_venv <resource-root> <old-root> [new-root]
#
# The rewrite exists because pip records the absolute interpreter path it built
# with; on macOS the tree moves between staging and the bundle, and on Linux it
# moves from the staging directory to /opt/letsmash.
mash_finish_skill_venv() {
  local res="$1"
  local old="${2:-}"
  local new="${3:-$1}"
  local venvs="$res/defaults/mash-config/venvs"
  local py="$res/python/bin/python3"
  local venv name
  [ -d "$venvs" ] || return 0
  [ -x "$py" ] || {
    echo "bundled Python is missing" >&2
    exit 1
  }
  for venv in "$venvs"/*; do
    [ -d "$venv" ] || continue
    name="$(basename "$venv")"
    if [ -n "$old" ] && [ "$old" != "$new" ]; then
      "$py" - "$venv" "$old" "$new" <<'PY'
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

mash_write_pins() {
  if [ ! -f "$root/packaging/pins.txt" ]; then
    mash_pins_text >"$root/packaging/pins.txt"
  fi
}
