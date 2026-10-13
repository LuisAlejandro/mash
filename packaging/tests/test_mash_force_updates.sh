#!/usr/bin/env bash
# mash_force_updates must pin the self-update switches off in every config Mash
# ships, including the JSON one for Fresh, without disturbing anything else.
set -euo pipefail

lib="${1:-$(cd "$(dirname "$0")/.." && pwd)/lib.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
cfg="$home/.mash/config"
mkdir -p "$cfg/herdr" "$cfg/ghostty" "$cfg/fresh"
touch "$home/.mash/force.marker"

# Pre-existing values are the wrong way round so the test proves a flip, and
# Fresh's file carries an unrelated key and nesting to prove the rest survives.
cat >"$cfg/herdr/config.toml" <<'EOF'
[update]
version_check = true
manifest_check = true
EOF
printf 'auto-update = on\n' >"$cfg/ghostty/config"
cat >"$cfg/fresh/config.json" <<'EOF'
{
  "theme": "monokai",
  "check_for_updates": true,
  "self_update": true,
  "editor": {
    "line_numbers": true
  }
}
EOF

env HOME="$home" bash -c 'source "$1"; mash_force_updates "$2"' _ "$lib" "$home"

grep -q '^version_check = false$' "$cfg/herdr/config.toml" || {
	echo "herdr version_check not forced false" >&2
	exit 1
}
grep -q '^manifest_check = false$' "$cfg/herdr/config.toml" || {
	echo "herdr manifest_check not forced false" >&2
	exit 1
}
grep -q '^auto-update = off$' "$cfg/ghostty/config" || {
	echo "ghostty auto-update not forced off" >&2
	exit 1
}

python3 - "$cfg/fresh/config.json" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
assert data["check_for_updates"] is False, data
assert data["self_update"] is False, data
assert data["theme"] == "monokai", data
assert data["editor"] == {"line_numbers": True}, data
PY

# A second run must be a no-op, not a growing pile of duplicate keys.
before="$(shasum -a 256 "$cfg/fresh/config.json")"
env HOME="$home" bash -c 'source "$1"; mash_force_updates "$2"' _ "$lib" "$home"
after="$(shasum -a 256 "$cfg/fresh/config.json")"
[ "$before" = "$after" ] || {
	echo "second run changed the file" >&2
	exit 1
}
[ "$(grep -c '"check_for_updates"' "$cfg/fresh/config.json")" = 1 ] || {
	echo "check_for_updates duplicated" >&2
	exit 1
}

# A config that never had the keys must gain them, still valid JSON.
cat >"$cfg/fresh/config.json" <<'EOF'
{
  "theme": "monokai"
}
EOF
env HOME="$home" bash -c 'source "$1"; mash_force_updates "$2"' _ "$lib" "$home"
python3 - "$cfg/fresh/config.json" <<'PY' || exit 1
import json, sys
data = json.load(open(sys.argv[1]))
assert data["check_for_updates"] is False, data
assert data["self_update"] is False, data
assert data["theme"] == "monokai", data
PY

echo "mash_force_updates: ok"
