#!/usr/bin/env bash
# Exercises mash-tool-install's package-to-shim rules without npm, pip or the
# network. A fake manifest, npm and python stand in for the pinned runtimes so
# the real helper code runs end to end:
#
#   * svelte-language-server installs svelteserver
#   * vscode-langservers-extracted installs all three language servers
#   * tailwindcss-language-server is accepted even though it rejects --version
#   * python-lsp-server installs pylsp, and its console script points at the
#     final venv rather than the temporary .new directory pip built it in
#   * raw binaries get their command name; Sentrux grammars stay in Mash's HOME
#   * a bad binary checksum never creates a shim
set -euo pipefail

helper="$(cd "$(dirname "$0")/.." && pwd)/mash-tool-install"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

res="$tmp/res"
data="$tmp/home/.mash"
mkdir -p "$res/bin" "$res/assets" "$res/node/bin" "$res/python/bin" "$data"

cp "$helper" "$res/bin/mash-tool-install"
chmod +x "$res/bin/mash-tool-install"

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
    elif component in ("svelte-language-server", "prettier-plugin-svelte"):
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
mkdir -p "$prefix/bin"
name="${package%@*}"
make_bin() {
  printf '#!/bin/sh\nexit 0\n' >"$prefix/bin/$1"
  chmod +x "$prefix/bin/$1"
}
case "$name" in
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
    MASH_DATA_DIR="$data" "$res/bin/mash-tool-install" "$@"
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
