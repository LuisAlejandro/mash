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
