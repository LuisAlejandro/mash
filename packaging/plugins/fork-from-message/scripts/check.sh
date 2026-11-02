#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m compileall -q scripts tests
python3 tests/test_fork_from_message.py
node --check scripts/pi_session.mjs
node tests/test_pi_session.mjs
