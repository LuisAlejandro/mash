#!/bin/bash
# Native fixture proof, not a substitute for signed-build About Mash sign-off.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS update lifecycle'; exit 77; fi
command -v xcrun >/dev/null
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for tag in 0.2.1 0.2.2; do
  if ! git -C "$ROOT" rev-parse --verify "$tag^{commit}" >/dev/null 2>&1; then
    git -C "$ROOT" fetch --quiet --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}"
  fi
done
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_lifecycle_checks.py"
