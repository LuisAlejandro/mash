#!/bin/bash
# Keep the existing suite entrypoint; the standard-library fixture uses real
# native identity/property-list tools and disposable bundles only.
set -euo pipefail
echo 'SKIP: covered by test_mash_update_checks.sh'
exit 77
