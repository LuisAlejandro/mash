#!/bin/bash
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS process identities'; exit 77; fi
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_process_checks.py"
