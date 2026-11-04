#!/bin/bash
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS atomic updater lifecycle'; exit 77; fi
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_apply_checks.py"
