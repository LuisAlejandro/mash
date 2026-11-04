#!/bin/bash
# One Python process for every macOS updater regression module. Each wrapper
# script used to spawn python separately; together they exceeded macOS CI time.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS updater checks'; exit 77; fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for tag in 0.2.1 0.2.2; do
  if ! git -C "$ROOT" rev-parse --verify "$tag^{commit}" >/dev/null 2>&1; then
    git -C "$ROOT" fetch --quiet --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}"
  fi
done
export PYTHONDONTWRITEBYTECODE=1
exec python3 -m unittest discover -s "$ROOT/packaging/tests" -p 'update_*_checks.py' -v
