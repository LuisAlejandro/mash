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
# shellcheck source=carry.sh
source "$root/packaging/carry.sh"

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

ghostty_src="${MASH_GHOSTTY_SRC:-$root/../ghostty}"
zig="${MASH_ZIG:-$(command -v zig || true)}"

for cmd in dpkg-deb dpkg-shlibdeps patchelf python3; do
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
rm -rf "$work"
mkdir -p "$product/bin" "$product/lib" "$work/npm-cache" "$work/pip-cache" "$stage/DEBIAN"

# --- Ghostty's GTK frontend ------------------------------------------------
# Built from the same pinned fork the macOS adapter uses, but this is the GTK
# frontend rather than the Swift app, so no Xcode and no .app bundle.
# -fno-sys=gtk4-layer-shell because Ubuntu 24.04 does not package it, and the
# flag makes Ghostty build its own copy into the prefix lib/.
echo "building Ghostty GTK from $ghostty_src @ $(git -c safe.directory="$ghostty_src" -C "$ghostty_src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
(
  cd "$ghostty_src"
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

# Icons come from Mash's own artwork, not Ghostty's, so the launcher never shows
# the upstream logo. Sizes match what hicolor-aware desktops ask for.
"$root/packaging/linux/render-icons.py" \
  "$root/branding/logo-solid.png" "$stage/usr/share/icons/hicolor" "$appid"

# --- launcher --------------------------------------------------------------
cat >"$product/bin/$launcher" <<'LAUNCHER'
#!/bin/sh
# Mash's Linux entry point. Resolves the product tree from itself so the same
# script works from the package and from a staged build, then hands Ghostty the
# pane command with Mash's environment already in place.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
product="$(cd "$here/.." && pwd)"
home="${HOME:?Mash needs HOME to locate ~/.mash}"
export MASH_BIN="$here:$product/node/bin:$product/python/bin:$home/.mash/bin"

if [ ! -x "$product/bin/herdr-pane" ]; then
  printf 'Mash is not fully installed: %s is missing.\n' "$product/bin/herdr-pane" >&2
  exit 1
fi
exec "$product/bin/ghostty" -e "$product/bin/herdr-pane" "$@"
LAUNCHER
chmod 755 "$product/bin/$launcher"

# --- shared payload --------------------------------------------------------
# Staged by the same helpers the macOS adapter uses. U2 owns moving the Node,
# Python, Pi and plugin payload here; this call is the seam it fills in.
mash_stage_linux_payload "$product" "$target"

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
sed -e "s#@VERSION@#$version#" \
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
