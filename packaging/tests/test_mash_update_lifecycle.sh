#!/bin/bash
# Native fixture proof, not a substitute for signed-build About Mash sign-off.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS update lifecycle'; exit 0; fi
command -v xcrun >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_lifecycle_checks.py"
