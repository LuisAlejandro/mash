#!/usr/bin/env bash
# Check the bundled Pi runtime's actual imports, not only `pi --version`.
# npm can satisfy Pi's ^1.1.0 codemode dependency with an incompatible minor.
#
# Four surfaces are proven, not one. The codemode tool imports the
# ./declarations and ./source subpaths; the sandbox the tool runs scripts
# through is imported lazily on the first script (execute.js) and imports the
# package ROOT; worker.js imports ./worker. A gate that only loads the tool
# reports PASS while every agent's first codemode script fails, which is how
# this broke the first time.
set -euo pipefail

res="$(cd "${1:?usage: test_pi_runtime.sh <resource-root>}" && pwd)"
node="$res/node/bin/node"
pi="$res/node/lib/node_modules/@earendil-works/pi-coding-agent"

# Resolved from the Pi package's own directory, the way Pi itself resolves
# them, so the pinned dependency is what gets loaded.
checks=(
  "./dist/extensions/codemode/tool.js"
  "./dist/extensions/codemode/execute.js"
  "@earendil-works/pi-codemode"
  "@earendil-works/pi-codemode/worker"
)

for specifier in "${checks[@]}"; do
  if ! (cd "$pi" && "$node" --input-type=module -e 'await import(process.argv[1])' "$specifier"); then
    echo "Pi Codemode cannot load $specifier from $res; check the pinned pi-codemode dependency" >&2
    exit 1
  fi
done
echo "Pi Codemode: PASS"

# Exercise the storage API against the freshly staged pin, even on builders
# without a host Pi. Runtime staging precedes plugin copying on both platforms.
root="$(cd "$(dirname "$0")/../.." && pwd)"
"$node" "$root/packaging/plugins/fork-from-message/tests/test_pi_session.mjs" "$pi"

# Check wizard models/auth and the embedded provider snapshot against this pin.
# Metadata inspection must never resolve credentials or use a network.
"$node" "$root/packaging/tests/test_wizard_model_catalog.mjs" "$pi"

# Credential reuse and endpoint connections, against the real lock, resolver and
# sockets: a temporary home and a loopback fixture only, never a real provider.
"$node" "$root/packaging/tests/test_wizard_credentials.mjs" "$pi"
"$node" "$root/packaging/tests/test_wizard_connections.mjs" "$pi"

# A saved local connection must carry text and tool calls through the real Pi
# client, not merely store a plausible API string.
"$node" "$root/packaging/tests/test_wizard_pi_client.mjs" "$pi"

# Every helper both entrypoints import must ship, not only the one called.
for helper in mash-pi-runtime.mjs mash-pi-credentials.mjs mash-pi-connect.mjs mash-pi-http.mjs; do
  [ -f "$res/bin/$helper" ] || {
    echo "Wizard helper $helper is missing from $res/bin" >&2
    exit 1
  }
done
# Imported with no script argument, so the entrypoint guard stays inert.
(cd / && MASH_CREDENTIALS="$res/bin/mash-pi-credentials.mjs" MASH_CONNECT="$res/bin/mash-pi-connect.mjs" \
  "$node" --input-type=module -e 'await import(process.env.MASH_CREDENTIALS); await import(process.env.MASH_CONNECT)')
echo "Wizard connection helpers: PASS"
