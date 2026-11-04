#!/bin/bash
# Regression cases from the full updater review; all resources are disposable.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then echo 'SKIP: macOS updater review regressions'; exit 77; fi
PYTHONDONTWRITEBYTECODE=1 python3 "$(dirname "$0")/update_review_checks.py"
