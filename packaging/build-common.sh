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

# Stage the Node and Python runtimes and the Pi packages they carry.
#
# Shared because the layout is identical on both platforms: the archive member
# name and the URL come from the manifest, so only the target differs. The
# shebang rewrite exists because npm writes absolute interpreter paths that
# would name the build machine once the tree is installed elsewhere.
#
#   mash_stage_runtimes <resource-root> <target>
#
# The Pi packages are passed in so a caller can state exactly what it expects;
# the macOS adapter and the Linux adapter ship the same list.
mash_pi_packages() {
  local component spec
  for component in pi pi-voice pi-subagents pi-ask-user pi-monokai-pro pi-web-search; do
    spec="$(mash_package_spec "$component")" || return 1
    printf '%s\n' "$spec"
  done
}

# "<npm name>@<pinned version>" for one npm component. Fails rather than
# returning a spec without a version, because that installs whatever is current.
mash_package_spec() {
  local component="$1" name version
  name="$(python3 "${MASH_ASSETS_PY:-$root/packaging/assets.py}" resolve-shell "$component" "$(python3 "${MASH_ASSETS_PY:-$root/packaging/assets.py}" target)" 2>/dev/null | sed -n 's/^PACKAGE=//p')"
  [ -n "$name" ] || name="$component"
  version="$(mash_version "$component")" || return 1
  printf '%s@%s\n' "$name" "$version"
}

mash_stage_runtimes() {
  local res="$1" target="$2" tmp_node tmp_py member
  [ -n "$res" ] || {
    echo "mash_stage_runtimes needs a resource root" >&2
    return 1
  }

  tmp_node="$(mktemp -d)"
  mash_fetch_tree node "$target" "$tmp_node" || {
    rm -rf "$tmp_node"
    return 1
  }
  member="$(cat "$tmp_node/.mash-member")"
  [ -d "$tmp_node/$member" ] || {
    echo "the node archive has no $member directory" >&2
    rm -rf "$tmp_node"
    return 1
  }
  mkdir -p "$res/node"
  cp -R "$tmp_node/$member/bin" "$tmp_node/$member/lib" "$res/node/"
  rm -rf "$tmp_node"

  tmp_py="$(mktemp -d)"
  mash_fetch_tree python "$target" "$tmp_py" || {
    rm -rf "$tmp_py"
    return 1
  }
  member="$(cat "$tmp_py/.mash-member")"
  [ -d "$tmp_py/$member" ] || {
    echo "the python archive has no $member directory" >&2
    rm -rf "$tmp_py"
    return 1
  }
  rm -rf "$res/python"
  cp -R "$tmp_py/$member" "$res/python"
  rm -rf "$tmp_py"

  # The Pi packages land in the runtime's own global prefix, which is how
  # `pi` resolves them without a user install and without touching the host.
  local npm_env_home
  npm_env_home="$(mktemp -d)"
  # npm's own entry point is `#!/usr/bin/env node`, so the runtime it belongs to
  # has to be on PATH or it reports a missing interpreter.
  env HOME="$npm_env_home" \
    PATH="$res/node/bin:$PATH" \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    npm_config_audit=false \
    "$res/node/bin/npm" install --global --prefix "$res/node" \
    $(mash_pi_packages) >/dev/null 2>&1 || {
    echo "could not install the Pi packages for $target" >&2
    rm -rf "$npm_env_home"
    return 1
  }
  rm -rf "$npm_env_home"

  mash_write_runtime_shims "$res"

  # The interactive companions the macOS build bundles. All are pinned per
  # architecture in the manifest, so the same call serves both platforms.
  local tool
  for tool in lazygit lazydocker pet atuin; do
    mash_fetch_pinned "$tool" "$target" "$res/bin" || {
      echo "could not stage $tool for $target" >&2
      return 1
    }
  done

  echo "staged node, python, the Pi packages and the bundled tools for $target"
}

# Interpreter and package-manager entry points every pane expects on PATH.
# python3 is also the choke point that keeps bytecode out of a read-only tree.
mash_write_runtime_shims() {
  local res="$1"
  mkdir -p "$res/bin"
  cat >"$res/bin/node" <<'EOF'
#!/bin/sh
exec "$(cd "$(dirname "$0")/../node/bin" && pwd)/node" "$@"
EOF
  cat >"$res/bin/npm" <<'EOF'
#!/bin/sh
exec "$(cd "$(dirname "$0")/../node/bin" && pwd)/npm" "$@"
EOF
  cat >"$res/bin/python3" <<'EOF'
#!/bin/sh
# Interpreter choke point for everything on a pane's PATH. A read-only product
# tree must not collect __pycache__, and every caller needs the bundled
# interpreter rather than whatever PATH resolves first.
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
exec "$(cd "$(dirname "$0")/../python/bin" && pwd)/python3" "$@"
EOF
  chmod 755 "$res/bin/node" "$res/bin/npm" "$res/bin/python3"

  # npm writes the absolute interpreter path into every bin script it creates.
  local node_real script
  node_real="$res/node/bin/node"
  while IFS= read -r script; do
    case "$(head -n 1 "$script" 2>/dev/null)" in
    "#!$node_real"*)
      {
        echo '#!/usr/bin/env node'
        tail -n +2 "$script"
      } >"$script.mashshebang"
      mv "$script.mashshebang" "$script"
      chmod 755 "$script"
      ;;
    esac
  done < <(find "$res/node" -type f 2>/dev/null)
}

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
