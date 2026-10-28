#!/bin/bash
# Build the Linux half of Mash: a staged FHS tree plus a letsmash .deb.
#
# Runs natively on the target: Ubuntu 24.04 x86_64 or arm64. Everything it
# needs is in the distro plus the pinned Ghostty fork checkout; nothing is
# downloaded at build time except tools the image already provides.
#
# Writes only under this repo's dist/. Does not install anything.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$root/packaging/lib.sh"
# shellcheck source=carry.sh
source "$root/packaging/carry.sh"
# shellcheck source=build-common.sh
source "$root/packaging/build-common.sh"

# The Debian package name, not the product name: Ubuntu already ships an
# unrelated bioinformatics package called `mash` that owns /usr/bin/mash.
pkgname="letsmash"
# Where the product tree lives after installation. Referenced by the desktop
# entry, so it is a package path, not a build path.
prefix="/opt/letsmash"
# The GTK application id, which also names the desktop entry and the icons.
# It must match `class` in packaging/defaults/ghostty/config.linux, or GNOME
# will not associate the window with the launcher.
appid="app.mash.Mash"
launcher="letsmash-launch"

# Shared staging resolves default checkout paths from the account home, the way
# the macOS adapter does.
home="$(mash_real_home)"
target="$(python3 "$root/packaging/assets.py" target)"
case "$target" in
linux-amd64) debarch="amd64" ;;
linux-arm64) debarch="arm64" ;;
*)
  echo "Mash builds Linux packages for linux-amd64 and linux-arm64 only; this is $target." >&2
  exit 1
  ;;
esac

work="$root/dist/.linux-build/$target"
# Build caches live outside the staging tree, which is wiped every run: a
# payload-only edit must not recompile Ghostty, and a checksum-pinned download
# must not be fetched twice. CI points this at its own cache directory.
cache="${MASH_BUILD_CACHE:-$root/dist/.cache}"
mkdir -p "$cache/downloads" "$cache/toolchains/$target" "$cache/cargo" \
  "$cache/cargo-target/$target" "$cache/go-mod" "$cache/go-build" \
  "$cache/zig/$target" "$cache/npm" "$cache/pip"
stage="$work/pkgroot"
productrel="${prefix#/}"
product="$stage/$productrel"
dest="$root/dist/${pkgname}_$(tr -d '[:space:]' <"$root/VERSION")_${debarch}.deb"

# The resource root shared staging fills; on Linux the product tree is the root.
export MASH_RES_ROOT="$product"

ghostty_src="${MASH_GHOSTTY_SRC:-$root/../ghostty}"
zig="${MASH_ZIG:-$(command -v zig || true)}"

for ghostty_patch in ghostty-gtk-branding.patch ghostty-gtk-window-layout.patch; do
  [ -f "$root/packaging/patches/$ghostty_patch" ] || {
    echo "missing $ghostty_patch" >&2
    exit 1
  }
done
for cmd in dpkg-deb dpkg-shlibdeps patchelf python3 patch; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing $cmd; install dpkg-dev, patchelf and python3" >&2
    exit 1
  }
done
[ -d "$ghostty_src/.git" ] || {
  echo "the Ghostty fork is missing at $ghostty_src" >&2
  echo "Clone it, or set MASH_GHOSTTY_SRC." >&2
  exit 1
}

# Same guard the macOS build runs: a rebase must not quietly bring a removed
# Ghostty feature back on either platform.
mash_ghostty_trim_check "$ghostty_src" || {
  echo "the Ghostty fork no longer matches what Mash ships" >&2
  exit 1
}
[ -n "$zig" ] && [ -x "$zig" ] || {
  echo "zig is missing; Ghostty pins its own compiler version." >&2
  echo "Set MASH_ZIG, or put zig on PATH." >&2
  exit 1
}
want_zig="$(sed -n 's/.*minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$ghostty_src/build.zig.zon")"
have_zig="$("$zig" version)"
[ "$want_zig" = "$have_zig" ] || {
  echo "zig is $have_zig, but the fork requires $want_zig." >&2
  exit 1
}

# Ghostty compiles its GTK interface from .blp files, so blueprint-compiler is a
# build dependency with a narrow window: Ubuntu 24.04 ships 0.12, which Ghostty
# rejects, and 0.20+ rejects Ghostty's own .blp files. The image must provide the
# pinned version, which no distribution packages.
want_bp="$(mash_assets pins | sed -n 's/^blueprint-compiler //p')"
command -v blueprint-compiler >/dev/null 2>&1 || {
  echo "blueprint-compiler is missing; the image must provide $want_bp" >&2
  exit 1
}
have_bp="$(blueprint-compiler --version 2>&1 | tail -1 | tr -d '[:space:]')"
[ "$have_bp" = "$want_bp" ] || {
  echo "blueprint-compiler is $have_bp, but this build requires $want_bp." >&2
  echo "0.20 and newer reject Ghostty's .blp files; 0.12 is too old." >&2
  exit 1
}

mash_require_sources
mash_pins_check

version="$(tr -d '[:space:]' <"$root/VERSION")"
[ -n "$version" ] || { echo "VERSION is empty." >&2; exit 1; }

echo "building $pkgname $version for $debarch ($target)"
# A previous run can leave the Go module cache read-only and a failed Cargo
# build can leave locked artifacts, either of which makes a plain rm fail and
# abort the next build before it starts.
chmod -R u+w "$work" 2>/dev/null || true
rm -rf "$work"
mkdir -p "$product/bin" "$product/lib" "$work/npm-cache" "$work/pip-cache" "$stage/DEBIAN"

# --- Ghostty's GTK frontend ------------------------------------------------
# Built from the same pinned fork the macOS adapter uses, but this is the GTK
# frontend rather than the Swift app, so no Xcode and no .app bundle.
# -fno-sys=gtk4-layer-shell because Ubuntu 24.04 does not package it, and the
# flag makes Ghostty build its own copy into the prefix lib/.
ghostty_commit="$(git -c safe.directory="$ghostty_src" -C "$ghostty_src" rev-parse HEAD 2>/dev/null || echo unknown)"
ghostty_sig="$ghostty_commit-$(cat \
  "$root/packaging/patches/ghostty-gtk-branding.patch" \
  "$root/packaging/patches/ghostty-gtk-window-layout.patch" |
  sha256sum | awk '{print $1}')"
ghostty_src_cache="$cache/ghostty-src/$target"
ghostty_out_cache="$cache/ghostty-out/$target"
echo "building Ghostty GTK from $ghostty_src @ ${ghostty_commit:0:9}"

if [ "${MASH_SKIP_GHOSTTY:-0}" = "1" ] && [ -d "$ghostty_out_cache" ]; then
  # Reuse path: a payload-only change must not pay for the terminal's compile.
  cp -a "$ghostty_out_cache/." "$product/"
  echo "reused the cached Ghostty frontend"
else
  # The patched source and its Zig cache are kept outside the staging tree, so
  # a rebuild recompiles only what actually changed.
  if [ ! -f "$ghostty_src_cache/.mash-ghostty-sig" ] ||
    [ "$(cat "$ghostty_src_cache/.mash-ghostty-sig")" != "$ghostty_sig" ]; then
    rm -rf "$ghostty_src_cache"
    mkdir -p "$ghostty_src_cache"
    tar -C "$ghostty_src" --exclude .git --exclude .zig-cache --exclude zig-out \
      -cf - . | tar -C "$ghostty_src_cache" -xf -
    if ! patch -p1 -d "$ghostty_src_cache" <"$root/packaging/patches/ghostty-gtk-branding.patch"; then
      echo "ghostty-gtk-branding.patch did not apply. The fork moved under it." >&2
      exit 1
    fi
    # The fork removed Ghostty's tab bar but left the terminal container
    # marked as a ToolbarView top bar. A top bar only gets its natural height,
    # which is two rows; the rest of the window stays empty. Make it content.
    if ! patch -p1 -d "$ghostty_src_cache" <"$root/packaging/patches/ghostty-gtk-window-layout.patch"; then
      echo "ghostty-gtk-window-layout.patch did not apply. The fork moved under it." >&2
      exit 1
    fi
    printf '%s\n' "$ghostty_sig" >"$ghostty_src_cache/.mash-ghostty-sig"
  fi
  (
    cd "$ghostty_src_cache"
    # The patched source cache lives under the Mash checkout. Without a Git
    # boundary, Ghostty's version probe finds Mash's release tag and mistakes
    # it for a Ghostty tag (vX.Y.Z), panicking. Treat the cache as the ceiling.
    GIT_CEILING_DIRECTORIES="$cache" PATH="$(dirname "$zig"):$PATH" \
      "$zig" build -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -p "$product" \
      --cache-dir "$cache/zig/$target/local" \
      --global-cache-dir "$cache/zig/$target/global"
  ) || {
    echo "the Ghostty GTK frontend failed to build." >&2
    exit 1
  }
  rm -rf "$ghostty_out_cache"
  mkdir -p "$ghostty_out_cache"
  cp -a "$product/." "$ghostty_out_cache/"
fi

[ -x "$product/bin/ghostty" ] || {
  echo "the Ghostty GTK frontend did not produce bin/ghostty" >&2
  exit 1
}

# zig build installs lib/libgtk4-layer-shell.so but leaves bin/ghostty looking
# for it through a build-directory RPATH (.zig-cache/o/<hash>), so a copied
# tree cannot start. Point it at the package's own lib/ instead of exporting a
# global library path, then prove it resolves from inside the package.
patchelf --set-rpath '$ORIGIN/../lib' "$product/bin/ghostty"
rpath="$(patchelf --print-rpath "$product/bin/ghostty")"
[ "$rpath" = '$ORIGIN/../lib' ] || {
  echo "could not set a portable RPATH on bin/ghostty (got '$rpath')" >&2
  exit 1
}
if ldd "$product/bin/ghostty" | grep -q "not found"; then
  echo "bin/ghostty has unresolved libraries after the RPATH fix:" >&2
  ldd "$product/bin/ghostty" | grep "not found" >&2
  exit 1
fi
# ldd resolves through the RPATH, so it prints the path un-normalised
# (bin/../lib/...). Compare where the library really lands, not how it
# happens to be spelled.
layer_real="$(readlink -f "$(ldd "$product/bin/ghostty" | awk '/gtk4-layer-shell/ {print $3}')" 2>/dev/null || true)"
product_real="$(readlink -f "$product")"
case "$layer_real" in
"$product_real/lib/"*) echo "ok: gtk4-layer-shell resolves inside the package" ;;
*)
  {
    echo "bin/ghostty does not resolve gtk4-layer-shell from the package lib/"
    echo "  resolved to:    ${layer_real:-<nothing>}"
    echo "  expected under: $product_real/lib/"
  } >&2
  exit 1
  ;;
esac

# --- Mash identity ---------------------------------------------------------
# Ghostty installs its own desktop entry, DBus service and metainfo under
# com.mitchellh.ghostty. Left in place, GNOME lists a second application called
# Ghostty, and DBus activation could start Mash without its environment.
rm -f "$product/share/applications/com.mitchellh.ghostty.desktop" \
  "$product/share/dbus-1/services/com.mitchellh.ghostty.service" \
  "$product/share/metainfo/com.mitchellh.ghostty.metainfo.xml" \
  "$product/share/kio/servicemenus/com.mitchellh.ghostty.desktop" \
  "$product/share/systemd/user/app-com.mitchellh.ghostty.service"
# Development artifacts are not part of a desktop install, and the .pc files
# record this build's staging prefix, so they would leak it into the package.
rm -rf "$product/include" "$product/share/pkgconfig"
rm -f "$product"/lib/libghostty-vt.*

apps="$stage/usr/share/applications"
mkdir -p "$apps"
sed -e "s#@APPID@#$appid#g" "$root/packaging/linux/app.desktop.in" >"$apps/$appid.desktop"
chmod 644 "$apps/$appid.desktop"

# MesloLGS NF ships with the package so the terminal looks the same as on macOS
# without asking the user to install a font. fontconfig discovers it from the
# system font tree, which is why the desktop entry does not name a path.
fonts="$stage/usr/share/fonts/truetype/meslo-lg-nerd-font"
mkdir -p "$fonts"
for ttf in "$root/packaging/fonts/"*.ttf; do
  [ -f "$ttf" ] || continue
  cp "$ttf" "$fonts/"
done
cp "$root/packaging/fonts/NOTICE.txt" "$fonts/" 2>/dev/null || true
chmod 644 "$fonts/"*

# Icons come from Mash's own artwork, not Ghostty's, so the launcher never shows
# the upstream logo. Sizes match what hicolor-aware desktops ask for.
"$root/packaging/linux/render-icons.py" \
  "$root/branding/logo-solid.png" "$stage/usr/share/icons/hicolor" "$appid"

# --- launcher --------------------------------------------------------------
# The launcher is a tracked file rather than a heredoc so it is linted and
# reviewed like every other shipped script.
cp "$root/packaging/linux/launcher" "$product/bin/$launcher"
chmod 755 "$product/bin/$launcher"

# --- shared payload --------------------------------------------------------
# The portable half comes from the one shared staging every adapter uses; only
# the runtime and frontend below are Linux-specific.
mash_stage_portable_payload "$product" "$target" || {
  echo "could not stage the shared payload" >&2
  exit 1
}
mash_stage_runtimes "$product" "$target" || {
  echo "could not stage the runtimes" >&2
  exit 1
}

# Rust and Go build Fresh, the wizard and two of the plugins. They are build
# dependencies, staged into the work tree and never shipped.
toolchain="$cache/toolchains/$target"
mash_ensure_toolchain rust "$target" "$toolchain/rust" || {
  echo "could not stage the rust toolchain" >&2
  exit 1
}
mash_ensure_toolchain go "$target" "$toolchain/go" || {
  echo "could not stage the go toolchain" >&2
  exit 1
}
export PATH="$toolchain/rust/bin:$toolchain/go/bin:$PATH"
# The downloaded Go owns its standard library; an inherited GOROOT from a host
# install makes its compile tool disagree about which release it is.
export GOROOT="$toolchain/go"
export GOTOOLCHAIN=local
export MASH_CARGO="$toolchain/rust/bin/cargo"
# Module downloads and compiled objects are the expensive part of the two Go
# plugins; both survive the staging wipe.
export GOMODCACHE="$cache/go-mod"
export GOCACHE="$cache/go-build"
export GOPATH="$cache/go-path"
export CARGO_TARGET_DIR="$cache/cargo-target/$target"
export MASH_CACHE="$cache"

mash_stage_fresh "$product" "$target" "$cache/cargo" || {
  echo "could not stage fresh" >&2
  exit 1
}
mash_stage_wizard "$product" "$cache/cargo" || {
  echo "could not stage the wizard" >&2
  exit 1
}
mash_stage_linux_runtime "$product" "$target" || {
  echo "could not stage the Linux runtime" >&2
  exit 1
}
# Skills and plugins are pinned checkouts in CI and on a maintainer machine.
# Both are staged from their own sources, never installed by their installers.
mash_install_skills || {
  echo "could not stage the skills payload" >&2
  exit 1
}
mash_build_plugins || {
  echo "could not stage the plugins" >&2
  exit 1
}

mash_verify_portable_payload "$product" || {
  echo "the staged payload is incomplete" >&2
  exit 1
}

# pip records the interpreter path it built the venv with, which here is the
# staging tree. Point it at the install prefix before anything is packaged, or
# the shipped venvs name a directory that only existed on the builder.
mash_finish_skill_venv "$product" "$product" "$prefix" || {
  echo "could not finish the skill venvs" >&2
  exit 1
}

# --- package metadata ------------------------------------------------------
# A staged file that names this build's staging path would break once
# installed, and Ghostty's own systemd unit does exactly that -- one reason it
# is removed above. Only the staging path is searched: /Users/, /Volumes/ and
# short roots all appear in legitimate comments and in the shared macOS scripts
# whose Linux branch never runs, so matching them reports noise, not defects.
if grep -rIlF -e "$work" "$product" 2>/dev/null | grep -q .; then
  echo "a staged file names this build's staging path:" >&2
  grep -rIlF -e "$work" "$product" 2>/dev/null | head -3 >&2
  exit 1
fi
# Dependencies are derived from the binary rather than guessed, so a library the
# linker actually needs cannot be missing from the package's Depends.
shlibdeps_dir="$work/shlibdeps"
mkdir -p "$shlibdeps_dir/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$pkgname" "$pkgname" \
  >"$shlibdeps_dir/debian/control"
shlibs_depends="$(
  cd "$shlibdeps_dir" &&
    dpkg-shlibdeps -O --ignore-missing-info "$product/bin/ghostty" 2>/dev/null |
    sed -n 's/^shlibs:Depends=//p'
)"
[ -n "$shlibs_depends" ] || {
  echo "could not derive package dependencies from bin/ghostty" >&2
  exit 1
}

maintainer="${MASH_MAINTAINER:-Luis Alejandro Martínez Faneyth <luis@letsma.sh>}"
installed_kb="$(du -sk --exclude=DEBIAN "$stage" | awk '{print $1}')"
# Runtime dependencies the payload invokes rather than links. rsync is how the
# launcher seeds ~/.mash without replacing the user's files; xdg-utils is the
# desktop-opener the panel and preview fallbacks use.
extra_depends="ca-certificates, rsync, xdg-utils"
sed -e "s#@EXTRA_DEPENDS@#$extra_depends#" \
  -e "s#@VERSION@#$version#" \
  -e "s#@ARCH@#$debarch#" \
  -e "s#@MAINTAINER@#$maintainer#" \
  -e "s#@INSTALLED_SIZE@#$installed_kb#" \
  -e "s#@DEPENDS@#$shlibs_depends#" \
  "$root/packaging/linux/control.in" >"$stage/DEBIAN/control"

# --- repository configuration ----------------------------------------------
# The package subscribes the machine to Mash's APT repository so later releases
# arrive through the ordinary system update. The signing key is shipped as a
# file dpkg owns, so purge removes it without a maintainer script touching it;
# postinst only writes the source. linux/README.md explains the policy.
for script in postrm; do
  [ -f "$root/packaging/linux/$script" ] || {
    echo "missing packaging/linux/$script" >&2
    exit 1
  }
  install -m 755 "$root/packaging/linux/$script" "$stage/DEBIAN/$script"
done
postinst="$stage/DEBIAN/postinst"
sed "s/@ARCH@/$debarch/g" "$root/packaging/linux/postinst" >"$postinst"
chmod 755 "$postinst"
keyring="$root/packaging/linux/letsmash-archive-keyring.gpg"
[ -f "$keyring" ] || {
  echo "missing $keyring; the package cannot trust the repository" >&2
  exit 1
}
install -D -m 644 "$keyring" "$stage/usr/share/keyrings/letsmash-archive-keyring.gpg"

# Reproducibility, precisely: the payload's file set, permissions and versions
# are stable for the same inputs, and timestamps are clamped. The archive is not
# guaranteed byte-identical across a cold Zig cache, because Zig reuses its
# global cache and emits different (equivalent) machine code -- so release
# verification compares the payload manifest, not a checksum of the build.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u -d "$(git -c safe.directory="$root" -C "$root" log -1 --format=%cI 2>/dev/null || date -u +%FT%TZ)" +%s)}"

rm -f "$dest"
dpkg-deb --build --root-owner-group "$stage" "$dest" >/dev/null
echo "built $dest"
echo "depends: $shlibs_depends"
