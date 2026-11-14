#!/bin/bash
# A plugin the bundle stops carrying must leave Herdr's registry.
#
# fork-from-message was dropped for Pi's own /fork. Its registry entry pointed
# into the bundle, and Herdr keeps a manifest copy there and lists its actions
# long after the directory is gone. mash_link_plugins prunes such entries --
# and only those: an owner's own install, under Herdr's plugin data directory,
# must survive even when its directory is missing for a moment.
#
# Run with: bash packaging/tests/test_link_plugins_prune.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

res="$tmp/res"
mkdir -p "$res/plugins/kept" "$res/bin" "$res/python/bin" "$tmp/config/herdr" "$tmp/data/herdr/plugins"
# The step runs the bundle python3. The resolved interpreter stands in for it:
# a `python3` on PATH can be a shim that finds its runtime relative to itself.
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$res/python/bin/python3"
printf 'id = "kept"\nversion = "1.0.0"\n' >"$res/plugins/kept/herdr-plugin.toml"
# The links themselves are not under test; record them and succeed.
printf '#!/bin/sh\necho "$@" >>"%s/links"\n' "$tmp" >"$res/bin/herdr"
chmod +x "$res/bin/herdr"

cat >"$tmp/config/herdr/plugins.json" <<JSON
[
  {"plugin_id": "kept", "version": "1.0.0", "plugin_root": "$res/plugins/kept"},
  {"plugin_id": "retired", "version": "0.2.3", "plugin_root": "$res/plugins/retired"},
  {"plugin_id": "owners", "version": "1.0.0", "plugin_root": "$tmp/data/herdr/plugins/owners"}
]
JSON

# shellcheck source=../launch-common.sh
source "$root/packaging/launch-common.sh"
XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" mash_link_plugins

ids="$(python3 -c 'import json, sys; print(" ".join(e["plugin_id"] for e in json.load(open(sys.argv[1]))))' \
  "$tmp/config/herdr/plugins.json")"
[ "$ids" = "kept owners" ] || {
  echo "registry after linking: '$ids', expected 'kept owners'" >&2
  exit 1
}
echo "ok - a plugin the bundle dropped is unregistered; an owner's install is kept"
