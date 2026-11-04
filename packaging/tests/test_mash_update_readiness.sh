#!/bin/bash
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS runtime readiness'; exit 77; fi
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_readiness_checks.py"
