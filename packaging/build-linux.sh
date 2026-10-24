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
stage="$work/pkgroot"
productrel="${prefix#/}"
product="$stage/$productrel"
dest="$root/dist/${pkgname}_$(tr -d '[:space:]' <"$root/VERSION")_${debarch}.deb"

# The resource root shared staging fills; on Linux the product tree is the root.
export MASH_RES_ROOT="$product"

ghostty_src="${MASH_GHOSTTY_SRC:-$root/../ghostty}"
zig="${MASH_ZIG:-$(command -v zig || true)}"

[ -f "$root/packaging/patches/ghostty-gtk-branding.patch" ] || {
  echo "missing the Ghostty branding patch" >&2
  exit 1
}
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
echo "building Ghostty GTK from $ghostty_src @ $(git -c safe.directory="$ghostty_src" -C "$ghostty_src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Build from a copy so the branding patch never mutates the pinned checkout,
# the same way Fresh is patched in a staged tree rather than in its original.
src="$work/ghostty"
rm -rf "$src"
mkdir -p "$src"
tar -C "$ghostty_src" --exclude .git --exclude .zig-cache --exclude zig-out -cf - . | tar -C "$src" -xf -
for branding in "$root/packaging/patches/ghostty-gtk-branding.patch"; do
  if ! patch -p1 -d "$src" <"$branding"; then
    echo "$(basename "$branding") did not apply. The fork moved under it." >&2
    exit 1
  fi
done
(
  cd "$src"
  PATH="$(dirname "$zig"):$PATH" \
    "$zig" build -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -p "$product"
) || {
  echo "the Ghostty GTK frontend failed to build." >&2
  exit 1
}
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
toolchain="$work/toolchain"
mash_stage_toolchain rust "$target" "$toolchain/rust" || {
  echo "could not stage the rust toolchain" >&2
  exit 1
}
mash_stage_toolchain go "$target" "$toolchain/go" || {
  echo "could not stage the go toolchain" >&2
  exit 1
}
export PATH="$toolchain/rust/bin:$toolchain/go/bin:$PATH"
# The downloaded Go owns its standard library; an inherited GOROOT from a host
# install makes its compile tool disagree about which release it is.
export GOROOT="$toolchain/go"
export GOTOOLCHAIN=local
export MASH_CARGO="$toolchain/rust/bin/cargo"

mash_stage_fresh "$product" "$target" "$work/cargo-home" || {
  echo "could not stage fresh" >&2
  exit 1
}
mash_stage_wizard "$product" "$work/cargo-home" || {
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
mash_install_design_skills || {
  echo "could not stage the design payload" >&2
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
extra_depends="rsync, xdg-utils"
sed -e "s#@EXTRA_DEPENDS@#$extra_depends#" \
  -e "s#@VERSION@#$version#" \
  -e "s#@ARCH@#$debarch#" \
  -e "s#@MAINTAINER@#$maintainer#" \
  -e "s#@INSTALLED_SIZE@#$installed_kb#" \
  -e "s#@DEPENDS@#$shlibs_depends#" \
  "$root/packaging/linux/control.in" >"$stage/DEBIAN/control"

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
