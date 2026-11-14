#!/usr/bin/env bash
# Preserve the plugin and window-launch entry point. Python's stdlib flock
# works on stock macOS and Linux without a platform-specific flock executable.
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/poll.py" "$@"
