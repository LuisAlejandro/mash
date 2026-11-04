#!/bin/bash
# Keep the existing suite entrypoint; the standard-library fixture uses real
# native identity/property-list tools and disposable bundles only.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS updater verification'; exit 0; fi
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_verify_checks.py"
