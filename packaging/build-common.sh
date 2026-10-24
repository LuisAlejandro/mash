#!/bin/bash
# Portable payload staging shared by the macOS and Linux adapters.
#
# Sourced by packaging/build.sh and packaging/build-linux.sh. Owns everything
# that is the same on both platforms and nothing that is not: no Xcode, no
# Mach-O relocation, no plists, no codesign, no dpkg. Platform adapters call
# mash_stage_portable_payload, then add their own runtime, terminal frontend and
# package metadata.
#
# Every function takes the resource root explicitly. That is the U2 contract:
# no shared code may reconstruct an .app path, so the same helpers stage a
# macOS Contents/Resources and a Linux /opt/letsmash identically.
#
# What this file owns today: the shared scripts, the shipped helpers, the seeded
# defaults, and the VERSION stamp.
# What still stages through packaging/carry.sh into a macOS-specific root, and
# therefore still has to be pointed at a resource root before Linux can claim
# full parity: the Node and Python runtimes, the Pi package install, the skills
# and design payloads, Fresh, and the in-repository plugins.

# The scripts a pane, the launcher and the plugins expect to find beside them.
mash_portable_scripts() {
  printf '%s\n' lib.sh mash-shell herdr-pane
}

# Stage the platform-neutral part of the payload into <resource-root>.
#
#   mash_stage_portable_payload <resource-root> [target]
#
# <target> is a manifest target name; it is only used to name the result in
# logs, because nothing here is architecture-specific.
mash_stage_portable_payload() {
  local res="$1" target="${2:-unknown}" name helper staged=0
  [ -n "$res" ] || {
    echo "mash_stage_portable_payload needs a resource root" >&2
    return 1
  }
  mkdir -p "$res/bin" "$res/defaults"

  for name in $(mash_portable_scripts); do
    [ -f "$root/packaging/$name" ] || {
      echo "missing shared script $name" >&2
      return 1
    }
    cp "$root/packaging/$name" "$res/bin/$name"
    chmod 755 "$res/bin/$name"
    staged=$((staged + 1))
  done

  # Only the shipped helpers: their tests and bytecode live beside them.
  for helper in "$root/packaging/helpers"/*; do
    [ -f "$helper" ] || continue
    case "$helper" in
    *.pyc) continue ;;
    esac
    cp "$helper" "$res/bin/"
    chmod 755 "$res/bin/$(basename "$helper")"
    staged=$((staged + 1))
  done

  # Seeded configuration, themes and plugin defaults. Read-only in the package,
  # copied to ~/.mash on first launch when the destination file is missing.
  if [ -d "$root/packaging/defaults" ]; then
    cp -R "$root/packaging/defaults/." "$res/defaults/"
  fi

  tr -d '[:space:]' <"$root/VERSION" >"$res/VERSION"

  echo "staged $staged shared program(s) and defaults for $target"
}

# Fail when a staged payload is missing something every Mash install needs,
# whoever assembled it. Called by both adapters so neither can ship a partially
# staged tree silently.
mash_verify_portable_payload() {
  local res="$1" name missing=0
  for name in $(mash_portable_scripts); do
    [ -x "$res/bin/$name" ] || {
      echo "payload is missing bin/$name" >&2
      missing=1
    }
  done
  [ -d "$res/defaults" ] || {
    echo "payload is missing defaults/" >&2
    missing=1
  }
  [ -f "$res/VERSION" ] || {
    echo "payload is missing VERSION" >&2
    missing=1
  }
  [ "$missing" -eq 0 ] || return 1
}
