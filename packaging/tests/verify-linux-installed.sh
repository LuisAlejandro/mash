#!/bin/bash
# Verify an installed letsmash package without installing it.
#
# The macOS adapter has verify-installed.sh for a .app tree; this is its Linux
# counterpart and the check U4's Definition of Done names. It extracts the .deb
# into a throwaway root and audits it the way a broken release would actually
# break: an ELF dependency that resolves to nothing, a build-machine path baked
# into the tree, or upstream Ghostty identity left in place.
#
#   packaging/tests/verify-linux-installed.sh <path-to.deb>
#
# Exit 0 = the package is internally consistent.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
deb="${1:-}"
[ -n "$deb" ] || {
  printf 'usage: %s <path-to.deb>\n' "$0" >&2
  exit 2
}
[ -f "$deb" ] || {
  printf 'no such package: %s\n' "$deb" >&2
  exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }

dpkg-deb -x "$deb" "$tmp/root" || {
  printf 'cannot extract %s\n' "$deb" >&2
  exit 2
}
product="$tmp/root/opt/letsmash"

# --- metadata -------------------------------------------------------------
if dpkg-deb -f "$deb" Package 2>/dev/null | grep -qx letsmash; then
  ok "package name is letsmash"
else
  fail "package name is not letsmash"
fi
arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)"
case "$arch" in
amd64 | arm64) ok "architecture is $arch" ;;
*) fail "unexpected architecture '$arch'" ;;
esac
[ -n "$(dpkg-deb -f "$deb" Version 2>/dev/null)" ] && ok "version is set" || fail "version is missing"
[ -n "$(dpkg-deb -f "$deb" Depends 2>/dev/null)" ] && ok "depends is set" || fail "depends is missing"

# --- product tree ---------------------------------------------------------
for entry in bin/ghostty bin/lib.sh bin/mash-shell bin/herdr-pane lib/libgtk4-layer-shell.so; do
  [ -e "$product/$entry" ] && ok "product has $entry" || fail "product is missing $entry"
done

# --- no public Mash CLI ---------------------------------------------------
# Ubuntu's bioinformatics package owns /usr/bin/mash; this package must not
# compete with it, and the product deliberately exposes no CLI.
if [ -e "$tmp/root/usr/bin/mash" ] || [ -e "$tmp/root/usr/bin/letsmash" ]; then
  fail "package installs a public CLI under /usr/bin"
else
  ok "no public CLI installed"
fi

# --- Ghostty identity must be gone ---------------------------------------
leftover=0
for entry in \
  usr/share/applications/com.mitchellh.ghostty.desktop \
  usr/share/dbus-1/services/com.mitchellh.ghostty.service \
  usr/share/metainfo/com.mitchellh.ghostty.metainfo.xml \
  opt/letsmash/share/applications/com.mitchellh.ghostty.desktop \
  opt/letsmash/share/dbus-1/services/com.mitchellh.ghostty.service \
  opt/letsmash/share/metainfo/com.mitchellh.ghostty.metainfo.xml; do
  [ -e "$tmp/root/$entry" ] && {
    fail "upstream Ghostty identity survives at $entry"
    leftover=1
  }
done
[ "$leftover" = 0 ] && ok "no upstream Ghostty desktop entry, service or metainfo"

# --- Mash desktop entry ---------------------------------------------------
desktop="$tmp/root/usr/share/applications/app.mash.Mash.desktop"
if [ -f "$desktop" ]; then
  ok "Mash desktop entry installed"
  grep -qx 'Name=Mash' "$desktop" && ok "desktop Name is Mash" || fail "desktop Name is not Mash"
  grep -qx 'StartupWMClass=app.mash.Mash' "$desktop" && ok "StartupWMClass matches the app id" ||
    fail "StartupWMClass does not match app.mash.Mash"
  grep -qx 'DBusActivatable=false' "$desktop" && ok "DBus activation is off" ||
    fail "DBus activation must be off so launches keep Mash's environment"
  grep -qE '^Exec=/opt/letsmash/bin/letsmash-launch' "$desktop" &&
    ok "desktop Exec points at the private launcher" || fail "desktop Exec is not the private launcher"
else
  fail "Mash desktop entry is missing"
fi

icons="$(find "$tmp/root/usr/share/icons" -name 'app.mash.Mash.png' 2>/dev/null | wc -l | tr -d ' ')"
[ "$icons" -ge 4 ] && ok "Mash icon set installed ($icons files)" || fail "Mash icon set is missing or sparse ($icons files)"

# --- ELF linkage ----------------------------------------------------------
if [ -x "$product/bin/ghostty" ]; then
  rpath="$(patchelf --print-rpath "$product/bin/ghostty" 2>/dev/null)"
  [ "$rpath" = '$ORIGIN/../lib' ] && ok "bin/ghostty has a portable RPATH" ||
    fail "bin/ghostty RPATH is '$rpath', not \$ORIGIN/../lib"

  unresolved="$(ldd "$product/bin/ghostty" 2>/dev/null | grep -c 'not found' || true)"
  [ "${unresolved:-0}" -eq 0 ] && ok "bin/ghostty resolves every library" ||
    fail "bin/ghostty has $unresolved unresolved libraries"

  layer="$(readlink -f "$(ldd "$product/bin/ghostty" 2>/dev/null | awk '/gtk4-layer-shell/ {print $3}')" 2>/dev/null || true)"
  product_real="$(readlink -f "$product")"
  case "$layer" in
  "$product_real/lib/"*) ok "gtk4-layer-shell resolves from inside the package" ;;
  *) fail "gtk4-layer-shell resolves to '${layer:-nothing}', not the package lib/" ;;
  esac
fi

# Every shipped executable must resolve, not only ghostty.
while IFS= read -r exe; do
  if file "$exe" 2>/dev/null | grep -q 'ELF'; then
    if ldd "$exe" 2>/dev/null | grep -q 'not found'; then
      fail "unresolved libraries: ${exe#"$tmp/root"}"
    fi
  fi
done < <(find "$tmp/root" -type f -perm -u+x 2>/dev/null)
ok "shipped executables audited for unresolved libraries"

# --- build-machine leakage ------------------------------------------------
# Only the staging marker is searched. /Users/, /Volumes/ and bare short roots
# appear in legitimate comments and in the shared macOS scripts whose Linux
# branch never runs, so they report noise instead of defects.
if grep -rIlF -e '.linux-build' "$tmp/root/opt" 2>/dev/null | grep -q .; then
  fail "the package names a build-machine path:"
  grep -rIlF -e '.linux-build' "$tmp/root/opt" 2>/dev/null | head -3 | sed 's/^/      /'
else
  ok "no build-machine paths in the product tree"
fi
if grep -rIl -e 'com.mitchellh.ghostty.service' "$tmp/root" 2>/dev/null | grep -q .; then
  fail "a unit file still names the upstream Ghostty service"
else
  ok "no upstream Ghostty unit file"
fi
if grep -rIl -e '\.zig-cache' "$tmp/root/usr/share/applications" 2>/dev/null | grep -q .; then
  fail "a desktop entry still names the build cache"
else
  ok "no desktop entry names the build cache"
fi

# --- the terminal actually runs ------------------------------------------
if [ -x "$product/bin/ghostty" ]; then
  if out="$(HOME="$tmp/home" "$product/bin/ghostty" +version 2>&1)"; then
    printf '%s\n' "$out" | grep -qi ghostty && ok "bin/ghostty runs and reports a version" ||
      fail "bin/ghostty ran but did not report a version"
  else
    fail "bin/ghostty could not run outside its build directory"
  fi
fi

echo
if [ "$failures" -eq 0 ]; then
  printf 'verify-linux-installed: PASSED\n'
  exit 0
fi
printf 'verify-linux-installed: FAILED (%d problem(s))\n' "$failures"
exit 1
