#!/usr/bin/env bash
# Exercises mash-tool-install's package-to-shim rules without npm, pip or the
# network. A fake manifest, npm and python stand in for the pinned runtimes so
# the real helper code runs end to end:
#
#   * bundled npm installs pinned packages under Mash's prefix, never host npm
#   * svelte-language-server installs svelteserver
#   * vscode-langservers-extracted installs all three language servers
#   * tailwindcss-language-server is accepted even though it rejects --version
#   * python-lsp-server installs pylsp, and its console script points at the
#     final venv rather than the temporary .new directory pip built it in
#   * raw binaries get their command name; Sentrux grammars stay in Mash's HOME
#   * a bad binary checksum never creates a shim
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/mash-tool-install"
# The macOS adapter selects helpers explicitly. A working installer that is
# absent from the DMG would leave the wizard unable to set up npm tools.
grep -qx '  mash-tool-install' "$(dirname "$helper")/../build.sh" || {
  echo "macOS build does not ship mash-tool-install" >&2
  exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

res="$tmp/res"
data="$tmp/home/.mash"
mkdir -p "$res/bin" "$res/assets" "$res/node/bin" "$res/python/bin" "$data"

cp "$helper" "$res/bin/mash-tool-install"
chmod +x "$res/bin/mash-tool-install"
cat >"$res/bin/python3" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$MASH_DATA_DIR/resolver-seen"
exec "$HOST_PYTHON" "$@"
SH
chmod +x "$res/bin/python3"

cat >"$res/assets/assets.py" <<'PY'
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
component = args[1] if len(args) > 1 else ""
target = args[2] if len(args) > 2 else ""
if args[:1] == ["target"]:
    print("linux-amd64")
elif args[:1] == ["resolve-shell"]:
    print(f"COMPONENT={component}")
    print(f"TARGET={target}")
    if component == "python-lsp-server":
        print("STRATEGY=pip")
        print("VERSION=1.0")
        print("PACKAGE=fake-pylsp")
    elif component == "git":
        print("STRATEGY=package")
        print("REFERENCE_VERSION=1.0")
    elif component == "prettier" and __import__("os").environ.get("FAKE_ASSETS_BAD_PRETTIER"):
        print("STRATEGY=package")
        print("REFERENCE_VERSION=1.0")
    elif component in ("svelte-language-server", "prettier-plugin-svelte", "prettier", "agent-browser"):
        print("STRATEGY=npm")
        print("VERSION=1.0")
    elif component == "vscode-langservers-extracted":
        print("STRATEGY=npm")
        print("VERSION=1.0")
    elif component == "tailwindcss-language-server":
        print("STRATEGY=npm")
        print("VERSION=1.0")
    elif component in ("sentrux", "latexindent", "bad-hash"):
        import hashlib
        from pathlib import Path
        root = Path(__import__("os").environ["FAKE_ASSETS_DIR"])
        member = {"sentrux": "sentrux-linux-x64", "latexindent": "latexindent-linux", "bad-hash": "latexindent-linux"}[component]
        source = root / member
        print("STRATEGY=binary")
        print("VERSION=1.0")
        print(f"URL=file://{source}")
        print(f"SHA256={hashlib.sha256(source.read_bytes()).hexdigest() if component != 'bad-hash' else '0' * 64}")
        print("ARCHIVE=raw")
        print(f"MEMBER={member}")
        if component == "sentrux":
            grammars = root / "grammars.tar.gz"
            print(f"GRAMMARS_URL=file://{grammars}")
            digest = '0' * 64 if (root / 'bad-grammars').exists() else hashlib.sha256(grammars.read_bytes()).hexdigest()
            print(f"GRAMMARS_SHA256={digest}")
    else:
        sys.exit(1)
elif args[:1] == ["applies"]:
    # Scoped out of this target by the manifest (4), or simply unknown (1).
    sys.exit(4 if component == "arm-only-tool" else 1)
else:
    sys.exit(1)
PY
chmod +x "$res/assets/assets.py"

# npm creates the bins the package declares, which is exactly where the helper
# has to look. tailwind's binary rejects both probes on purpose.
cat >"$res/node/bin/npm" <<'SH'
#!/bin/sh
set -eu
prefix=""
package=""
while [ $# -gt 0 ]; do
  case "$1" in
  --prefix) prefix="$2"; shift 2 ;;
  install|--global|--prefix=*) shift ;;
  *) package="$1"; shift ;;
  esac
done
printf '%s|%s|%s|%s\n' "$prefix" "$package" "$HOME" "$npm_config_cache" >>"$MASH_DATA_DIR/npm-seen"
mkdir -p "$prefix/bin"
name="${package%@*}"
make_bin() {
  printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/$1"
  chmod +x "$prefix/bin/$1"
}
case "$name" in
prettier)
  printf '#!/usr/bin/env node\n' >"$prefix/bin/prettier"
  chmod +x "$prefix/bin/prettier"
  ;;
svelte-language-server) make_bin svelteserver ;;
vscode-langservers-extracted)
  make_bin vscode-css-language-server
  make_bin vscode-json-language-server
  make_bin vscode-html-language-server
  ;;
tailwindcss-language-server)
  printf '#!/bin/sh\nexit 1\n' >"$prefix/bin/tailwindcss-language-server"
  chmod +x "$prefix/bin/tailwindcss-language-server"
  ;;
*) make_bin "${name##*/}" ;;
esac
SH
chmod +x "$res/node/bin/npm"
cat >"$res/node/bin/node" <<'SH'
#!/bin/sh
printf '%s\n' "$0" >>"$MASH_DATA_DIR/node-seen"
exit 0
SH
chmod +x "$res/node/bin/node"

# python -m venv builds a venv whose python can install one package. The
# console script pip writes names the .new path, the bug the helper has to
# repair after it renames the directory.
cat >"$res/python/bin/python3" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
  dir="$3"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/python" <<'PY'
#!/bin/sh
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
  dir="$(cd "$(dirname "$0")" && pwd)"
  {
    printf '#!%s/python\n' "$dir"
    printf 'exit 0\n'
  } >"$dir/pylsp"
  chmod +x "$dir/pylsp"
  exit 0
fi
exit 0
PY
  chmod +x "$dir/bin/python"
  ln -s python "$dir/bin/python3"
  exit 0
fi
exit 0
SH
chmod +x "$res/python/bin/python3"

cat >"$res/assets/sentrux-linux-x64" <<'SH'
#!/bin/sh
printf '%s\n' "$HOME" >"$MASH_DATA_DIR/sentrux-home-seen"
echo "sentrux 1.0"
SH
cat >"$res/assets/latexindent-linux" <<'SH'
#!/bin/sh
echo "latexindent 1.0"
SH
mkdir -p "$res/assets/grammar/lang/grammars"
printf 'fake grammar\n' >"$res/assets/grammar/lang/grammars/linux-x86_64.so"
tar -czf "$res/assets/grammars.tar.gz" -C "$res/assets/grammar" lang

run() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin FAKE_ASSETS_DIR="$res/assets" \
    HOST_PYTHON="$(command -v python3)" MASH_DATA_DIR="$data" \
    "$res/bin/mash-tool-install" "$@"
}

# Host entries have no VERSION at all: with nounset this catches accidental
# use of the informational reference as though it were a real pin.
run git
[ ! -e "$data/bin/git" ] || {
  echo "host reference unexpectedly created a Mash-owned shim" >&2
  exit 1
}

run agent-browser
run prettier
for component in agent-browser prettier; do
  [ -x "$data/bin/$component" ] || {
    echo "$component has no Mash shim" >&2
    exit 1
  }
  grep -Fx "$data/local/npm|$component@1.0|$data|$data/cache/npm" "$data/npm-seen" >/dev/null || {
    echo "$component was not installed by bundled npm into Mash's prefix" >&2
    exit 1
  }
done
grep -Fx "$res/node/bin/node" "$data/node-seen" >/dev/null || {
  echo "prettier did not use Mash's bundled Node" >&2
  exit 1
}
if [ "$(uname -s)" = Darwin ]; then
  [ "$(head -n 1 "$data/local/npm/bin/prettier")" = '#!/usr/bin/env node' ] || {
    echo "macOS npm bin was tied to an app path instead of being relocatable" >&2
    exit 1
  }
  mkdir -p "$tmp/moved/node/bin"
  cp "$res/node/bin/node" "$tmp/moved/node/bin/node"
  env -i PATH="$tmp/moved/node/bin:/usr/bin:/bin" MASH_DATA_DIR="$data" \
    "$data/bin/prettier" --version
  grep -Fx "$tmp/moved/node/bin/node" "$data/node-seen" >/dev/null || {
    echo "prettier did not follow Mash's bundled Node after moving the app" >&2
    exit 1
  }
fi
[ ! -e "$tmp/home/.local/bin/agent-browser" ] || {
  echo "npm installer wrote outside Mash's data directory" >&2
  exit 1
}
grep -F 'resolve-shell agent-browser' "$data/resolver-seen" >/dev/null || {
  echo "Mash's bundled Python did not resolve the npm pin" >&2
  exit 1
}
mkdir "$data/setup/tool-install.lock"
if run prettier; then
  echo "a busy install lock incorrectly reported success" >&2
  exit 1
fi
rmdir "$data/setup/tool-install.lock"

if env -i HOME="$tmp/home" PATH=/usr/bin:/bin FAKE_ASSETS_DIR="$res/assets" \
  FAKE_ASSETS_BAD_PRETTIER=1 HOST_PYTHON="$(command -v python3)" \
  MASH_DATA_DIR="$data" MASH_INSTALL_NPM_ONLY=1 \
  "$res/bin/mash-tool-install" prettier; then
  echo "macOS npm step accepted an unpinned host package" >&2
  exit 1
fi
grep -F 'prettier requires an npm pin' "$data/setup/tool-install.log" >/dev/null || {
  echo "macOS npm step failed for the wrong reason" >&2
  exit 1
}

run svelte-language-server
[ -x "$data/bin/svelteserver" ] || {
  echo "svelte-language-server did not create a svelteserver shim" >&2
  exit 1
}

# A library-only npm package has no shim names. Bash 3.2 with nounset must not
# expand an empty array in the post-install loop.
run prettier-plugin-svelte
[ ! -e "$data/bin/prettier-plugin-svelte" ] || {
  echo "prettier-plugin-svelte unexpectedly created a shim" >&2
  exit 1
}

run vscode-langservers-extracted
for name in vscode-css-language-server vscode-json-language-server vscode-html-language-server; do
  [ -x "$data/bin/$name" ] || {
    echo "vscode-langservers-extracted did not create $name" >&2
    exit 1
  }
done

# The LSP rejects --version and --help; the helper must not call that a failure.
run tailwindcss-language-server
[ -x "$data/bin/tailwindcss-language-server" ] || {
  echo "tailwindcss-language-server did not install" >&2
  exit 1
}

run python-lsp-server
pylsp="$(readlink -f "$data/bin/pylsp" 2>/dev/null || true)"
[ -n "$pylsp" ] || {
  echo "python-lsp-server did not create a pylsp shim" >&2
  exit 1
}
case "$(head -n 1 "$pylsp")" in
*".new/bin/python")
  echo "pylsp still points at the temporary venv: $(head -n 1 "$pylsp")" >&2
  exit 1
  ;;
esac
"$data/bin/pylsp" --version >/dev/null 2>&1 || {
  echo "pylsp does not run after installation" >&2
  exit 1
}

# These pinned release binaries are Linux-only; macOS setup uses Homebrew.
if [ "$(uname -s)" = Linux ]; then
  touch "$res/assets/bad-grammars"
  if run sentrux; then
    echo "bad Sentrux grammar checksum did not fail" >&2
    exit 1
  fi
  [ ! -e "$data/bin/sentrux" ] || {
    echo "bad grammar checksum created a Sentrux shim" >&2
    exit 1
  }
  rm "$res/assets/bad-grammars"
  run sentrux
  [ "$(cat "$data/sentrux-home-seen")" = "$data" ] &&
    [ -f "$data/.sentrux/plugins/lang/grammars/linux-x86_64.so" ] &&
    [ ! -e "$tmp/home/.sentrux" ] || {
    echo "sentrux state or grammars escaped Mash's data directory" >&2
    exit 1
  }
  run latexindent
  [ "$(readlink "$data/bin/latexindent")" = "$data/local/tools/latexindent/1.0/latexindent" ] || {
    echo "raw binary was not installed under its command name" >&2
    exit 1
  }
  if run bad-hash; then
    echo "bad binary checksum did not fail" >&2
    exit 1
  fi
  [ ! -e "$data/bin/bad-hash" ] || {
    echo "bad binary checksum created a shim" >&2
    exit 1
  }
fi

# A tool the manifest scopes out of the target (Sentrux and latexindent publish no
# Intel Mac build) is not a failed install: it exits 4, which setup reports and
# skips, and it leaves nothing behind. Anything else that cannot resolve still
# exits 1, so a real failure is never mistaken for an absent tool.
status=0
run arm-only-tool || status=$?
[ "$status" = 4 ] || {
  echo "a tool scoped out of the target exited $status, not 4" >&2
  exit 1
}
[ ! -e "$data/bin/arm-only-tool" ] && [ ! -e "$data/local/tools/arm-only-tool" ] || {
  echo "a tool scoped out of the target left files behind" >&2
  exit 1
}
grep -q 'arm-only-tool is not available for linux-amd64' "$data/setup/tool-install.log" || {
  echo "the log does not say why arm-only-tool was skipped" >&2
  exit 1
}
status=0
run no-such-tool || status=$?
[ "$status" = 1 ] || {
  echo "an unknown tool exited $status, not 1" >&2
  exit 1
}

# macOS pinned release binaries, against the real manifest and the real
# downloads: an unversioned formula cannot honour a pin, so these four must
# install from the manifest and answer with the pinned version. Network-bound,
# so it is skipped when the downloads are unavailable.
if [ "$(uname -s)" = Darwin ] && [ "${MASH_TOOL_INSTALL_NETWORK:-0}" = 1 ]; then
  real="$tmp/real"
  mkdir -p "$real/bin" "$real/assets"
  cp "$helper" "$real/bin/mash-tool-install"
  chmod +x "$real/bin/mash-tool-install"
  repo_root="$(cd "$(dirname "$helper")/../.." && pwd)"
  cp "$repo_root/packaging/assets.json" "$repo_root/packaging/assets.py" "$real/assets/"
  realdata="$tmp/realhome/.mash"
  mkdir -p "$realdata"

  host_target="$(python3 "$real/assets/assets.py" target)"
  for component in marksman texlab latexindent sentrux rust-analyzer; do
    # Sentrux and latexindent have no macos-amd64 build, so the manifest scopes
    # them out of that target: they must report "not available" (4), not fail.
    applies=0
    python3 "$real/assets/assets.py" applies "$component" "$host_target" || applies=$?
    if [ "$applies" = 4 ]; then
      status=0
      env -i HOME="$tmp/realhome" PATH=/usr/bin:/bin MASH_DATA_DIR="$realdata" \
        MASH_INSTALL_BINARY_ONLY=1 "$real/bin/mash-tool-install" "$component" || status=$?
      [ "$status" = 4 ] || {
        echo "$component is not pinned for $host_target but exited $status, not 4" >&2
        exit 1
      }
      continue
    fi
    if ! env -i HOME="$tmp/realhome" PATH=/usr/bin:/bin MASH_DATA_DIR="$realdata" \
      MASH_INSTALL_BINARY_ONLY=1 "$real/bin/mash-tool-install" "$component"; then
      echo "$component did not install from the manifest on macOS" >&2
      tail -5 "$realdata/setup/tool-install.log" >&2
      exit 1
    fi
    [ -x "$realdata/bin/$component" ] || {
      echo "$component has no shim in Mash's bin" >&2
      exit 1
    }
  done

  # The shim must run and report the pinned version, not a host copy's.
  want_marksman="$(python3 "$real/assets/assets.py" resolve-shell marksman macos-arm64 | sed -n 's/^VERSION=//p')"
  got_marksman="$(env -i PATH=/usr/bin:/bin "$realdata/bin/marksman" --version 2>&1 | tr -d '[:space:]')"
  [ "$got_marksman" = "$want_marksman" ] || {
    echo "marksman reports '$got_marksman', manifest pins '$want_marksman'" >&2
    exit 1
  }
  env -i PATH=/usr/bin:/bin "$realdata/bin/texlab" --version >/dev/null 2>&1 || {
    echo "texlab did not run after installation" >&2
    exit 1
  }

  # Sentrux keeps its state and checksummed grammars inside Mash's data folder.
  # Where the manifest scopes it out (macos-amd64) there is nothing to check.
  if python3 "$real/assets/assets.py" applies sentrux "$host_target"; then
    [ -d "$realdata/.sentrux/plugins" ] || {
      echo "sentrux grammars were not installed into Mash's data folder" >&2
      exit 1
    }
    [ ! -e "$tmp/realhome/.sentrux" ] || {
      echo "sentrux wrote into the real home" >&2
      exit 1
    }
  fi

  # The pinned step must refuse a component that is not a pinned binary.
  if env -i HOME="$tmp/realhome" PATH=/usr/bin:/bin MASH_DATA_DIR="$realdata" \
    MASH_INSTALL_BINARY_ONLY=1 "$real/bin/mash-tool-install" jq; then
    echo "the pinned step accepted a host package" >&2
    exit 1
  fi
fi
