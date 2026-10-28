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

run() {
  env -i HOME="$tmp/home" PATH=/usr/bin:/bin \
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
