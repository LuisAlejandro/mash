#!/bin/bash
# mash-seed-sync must refresh the defaults Mash owns and nothing else.
#
# The rule under test is provenance: a file Mash wrote is Mash's to update while
# it still matches what Mash wrote; the moment it differs it belongs to the user;
# a file Mash never wrote is never touched. Before this existed, seeding only
# filled gaps, so a changed default never reached an existing installation.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
sync="$root/packaging/helpers/mash-seed-sync"

[ -x "$sync" ] || {
  echo "missing $sync" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

res="$tmp/res"
d="$tmp/data"
record="$d/local/state/seeded.json"
failures=0
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
ok() { printf 'ok    %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# Record queries, kept out of eval'd strings so quoting stays readable.
rec_version() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$record"
}
rec_count() {
  python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["files"]))' "$record"
}
rec_has() {
  python3 -c 'import json,sys;sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["files"] else 1)' "$record" "$1"
}

# A minimal resource root holding two of the trees the helper reconciles, so a
# missing tree (as on a platform that does not ship it) is also exercised.
# defaults/pi holds the agent directory's contents, not an agent/ subdirectory.
mkres() {
  local version="$1" default_body="$2"
  rm -rf "$res"
  mkdir -p "$res/defaults/pi/skills/demo" "$res/defaults/pi/extensions"
  printf '%s\n' "$version" >"$res/VERSION"
  printf '%s\n' "$default_body" >"$res/defaults/pi/skills/demo/SKILL.md"
  ln -s "SKILL.md" "$res/defaults/pi/skills/demo/current"
  printf 'quick reference %s\n' "$version" >"$res/defaults/pi/extensions/keybindings-quickref.txt"
  python3 - "$res/defaults/pi/mcp.json" "$version" <<'PY'
import json,sys
path,version=sys.argv[1:]
json.dump({"mcpServers":{"mcp-a":{"url":f"https://a/{version}"},"mcp-b":{"url":f"https://b/{version}"}}},open(path,"w"),indent=2)
PY
  mkdir -p "$res/defaults/ghostty/themes"
  printf 'theme %s\n' "$version" >"$res/defaults/ghostty/themes/Monokai"
  mkdir -p "$res/defaults/herdr" "$res/defaults/ghostty" "$res/defaults/zsh" \
    "$res/defaults/git" "$res/defaults/pet" "$res/defaults/fresh"
  cat >"$res/defaults/herdr/config.toml" <<'EOF'
[terminal]
default_shell = "__MASH_SHELL__"
config = "__MASH_CONFIG__"
[update]
version_check = true
manifest_check = true
EOF
  cat >"$res/defaults/ghostty/config" <<'EOF'
command = __MASH_HERDR_PANE__
working-directory = inherit
auto-update = on
EOF
  printf 'zsh %s\n' "$version" >"$res/defaults/zsh/.zshenv"
  printf 'git %s\n' "$version" >"$res/defaults/git/config"
  printf 'ignore %s\n' "$version" >"$res/defaults/git/ignore"
  printf 'snippet %s\n' "$version" >"$res/defaults/pet/snippet.toml"
  printf '[General]\nsnippetfile = "__MASH_PET_SNIPPET__"\n' >"$res/defaults/pet/config.toml"
  printf '{\n  "check_for_updates": true,\n  "self_update": true,\n  "label": "%s"\n}\n' "$version" >"$res/defaults/fresh/config.json"
  # The helper seeds the platform's variant: Linux ships .linux files beside the
  # macOS ones. Mirror them so the same assertions hold on both CI lanes.
  cp "$res/defaults/herdr/config.toml" "$res/defaults/herdr/config.linux.toml"
  cp "$res/defaults/ghostty/config" "$res/defaults/ghostty/config.linux"
  cp "$res/defaults/fresh/config.json" "$res/defaults/fresh/config.linux.json"
  cp "$res/defaults/pi/extensions/keybindings-quickref.txt" \
    "$res/defaults/pi/extensions/keybindings-quickref.linux.txt"
  mkdir -p "$res/defaults/mash-config/venvs/mash-parallel/bin" "$res/python/bin"
  cat >"$res/defaults/mash-config/venvs/mash-parallel/pyvenv.cfg" <<'EOF'
home = /build/python/bin
executable = /build/python/bin/python3
include-system-site-packages = false
EOF
  ln -s "../python" "$res/defaults/mash-config/venvs/mash-parallel/bin/python"
  printf '#!/build/venv/bin/python\nprint("runner")\n' \
    >"$res/defaults/mash-config/venvs/mash-parallel/bin/runner"
}

run_sync() { PYTHONDONTWRITEBYTECODE=1 "$sync" "$res" "$d"; }

mkdir -p "$d"
mkres 1.0.0 "v1 content"
run_sync >/dev/null 2>&1
chk "seed copies shipped files" '[ -f "$d/pi/agent/skills/demo/SKILL.md" ]'
chk "record written" '[ -f "$record" ]'
chk "record names the version" '[ "$(rec_version)" = "1.0.0" ]'
# 17 on both platforms: the .linux variants inside copied trees are themselves
# seeded (as mash_seed_missing's rsync already does) and so are recorded too.
chk "record digests copied trees, configs and venv" '[ "$(rec_count)" = 17 ]'
chk "record tracks bundled MCP servers separately" 'python3 - "$record" <<PY
import json,sys
servers=json.load(open(sys.argv[1]))["json"]["pi/agent/mcp.json"]
sys.exit(0 if set(servers)=={"mcp-a","mcp-b"} else 1)
PY'
chk "Mash symlink copied as a symlink" '[ -L "$d/pi/agent/skills/demo/current" ]'
if grep -Fqx "default_shell = \"$d/bin/mash-shell\"" "$d/config/herdr/config.toml" &&
  grep -qx "version_check = false" "$d/config/herdr/config.toml"; then
  ok "Herdr template rendered and forced values applied"
else
  fail "Herdr template rendered and forced values applied"
fi
chk "Ghostty path template rendered and forced values applied" 'grep -qx "command = $res/bin/herdr-pane" "$d/config/ghostty/config" && grep -qx "auto-update = off" "$d/config/ghostty/config"'
chk "Fresh self-update switches forced off" 'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d[\"check_for_updates\"] is False and d[\"self_update\"] is False else 1)" "$d/config/fresh/config.json"'
if grep -Fqx "snippetfile = \"$d/config/pet/snippet.toml\"" "$d/config/pet/config.toml"; then
  ok "pet config path rendered"
else
  fail "pet config path rendered"
fi
chk "parallel venv Python link retargeted" '[ "$(readlink "$d/config/mash/venvs/mash-parallel/bin/python")" = "$res/python/bin/python3" ]'
chk "parallel venv metadata retargeted" 'grep -qx "home = $res/python/bin" "$d/config/mash/venvs/mash-parallel/pyvenv.cfg"'
chk "parallel venv script shebang retargeted" 'head -1 "$d/config/mash/venvs/mash-parallel/bin/runner" | grep -Fqx "#!$d/config/mash/venvs/mash-parallel/bin/python"'

echo "-- second launch at the same version changes nothing"
cp "$record" "$tmp/before.json"
run_sync >/dev/null 2>&1
chk "record unchanged" 'cmp -s "$tmp/before.json" "$record"'

echo "-- stale lock is recovered on the next version change"
mkres 1.0.1 "v1.0.1 content"
mkdir -p "$d/local/state/seeded.lock"
printf '%s\n' 99999999 >"$d/local/state/seeded.lock/pid"
run_sync >/dev/null 2>&1
chk "stale lock removed" '[ ! -e "$d/local/state/seeded.lock" ]'
chk "upgrade proceeded" '[ "$(rec_version)" = "1.0.1" ]'

echo "-- concurrent launches serialize the ownership transaction"
mkres 1.0.2 "v1.0.2 content"
run_sync >"$tmp/concurrent-a.log" 2>&1 &
p1=$!
run_sync >"$tmp/concurrent-b.log" 2>&1 &
p2=$!
wait "$p1"
r1=$?
wait "$p2"
r2=$?
chk "both launch syncs completed" '[ "$r1" = 0 ] && [ "$r2" = 0 ]'
chk "single current record committed" '[ "$(rec_version)" = "1.0.2" ]'
chk "lock released" '[ ! -e "$d/local/state/seeded.lock" ]'

echo "-- a new release refreshes an untouched file and preserves an edited one"
printf 'user edited this\n' >"$d/pi/agent/skills/demo/SKILL.md"
rm "$d/pi/agent/skills/demo/current"
ln -s "../user-target" "$d/pi/agent/skills/demo/current"
printf 'other\n' >"$d/pi/agent/skills/other.md"
# User edits one shipped MCP server and adds their own servers. Reconciliation
# updates the other Mash-shipped server by key, not by replacing mcp.json.
python3 - "$d/pi/agent/mcp.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["mcpServers"]["mcp-a"]={"url":"https://user-edited"}; d["mcpServers"]["user-server"]={"command":"my-tool"}; d["mcpServers"]["penpot-local"]={"env":{"TOKEN":"user-secret"}}; json.dump(d,open(p,"w"),indent=2)
PY
mkres 1.1.0 "v2 content"
printf 'theme v2\n' >"$res/defaults/ghostty/themes/Monokai"
run_sync >/dev/null 2>&1
chk "edited file keeps user content" 'grep -qx "user edited this" "$d/pi/agent/skills/demo/SKILL.md"'
chk "untouched file takes the new content" 'grep -qx "theme v2" "$d/config/ghostty/themes/Monokai"'
chk "user-owned file untouched" 'grep -qx "other" "$d/pi/agent/skills/other.md"'
chk "user-replaced symlink preserved" '[ "$(readlink "$d/pi/agent/skills/demo/current")" = "../user-target" ]'
chk "edited MCP entry preserved" 'python3 - "$d/pi/agent/mcp.json" <<PY
import json,sys
d=json.load(open(sys.argv[1]));sys.exit(0 if d["mcpServers"]["mcp-a"]["url"] == "https://user-edited" else 1)
PY'
chk "untouched MCP entry refreshed" 'python3 - "$d/pi/agent/mcp.json" <<PY
import json,sys
d=json.load(open(sys.argv[1]));sys.exit(0 if d["mcpServers"]["mcp-b"]["url"] == "https://b/1.1.0" else 1)
PY'
chk "user MCP servers preserved" 'python3 - "$d/pi/agent/mcp.json" <<PY
import json,sys
d=json.load(open(sys.argv[1]))["mcpServers"];sys.exit(0 if d["user-server"]["command"] == "my-tool" and d["penpot-local"]["env"]["TOKEN"] == "user-secret" else 1)
PY'
chk "record advanced" '[ "$(rec_version)" = "1.1.0" ]'

echo "-- a dropped default is removed only when unmodified"
mkres 1.2.0 "v3 content"
rm -f "$res/defaults/ghostty/themes/Monokai"
python3 - "$res/defaults/pi/mcp.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["mcpServers"].pop("mcp-b"); json.dump(d,open(p,"w"),indent=2)
PY
run_sync >/dev/null 2>&1
chk "unmodified dropped file removed" '[ ! -e "$d/config/ghostty/themes/Monokai" ]'
chk "record forgot it" '! rec_has config/ghostty/themes/Monokai'
chk "edited file still present" '[ -f "$d/pi/agent/skills/demo/SKILL.md" ]'
chk "dropped unchanged MCP server removed" 'python3 - "$d/pi/agent/mcp.json" <<PY
import json,sys
d=json.load(open(sys.argv[1]))["mcpServers"];sys.exit(0 if "mcp-b" not in d else 1)
PY'
chk "user-added MCP server remains" 'python3 - "$d/pi/agent/mcp.json" <<PY
import json,sys
d=json.load(open(sys.argv[1]))["mcpServers"];sys.exit(0 if "user-server" in d and "penpot-local" in d else 1)
PY'

echo "-- an installation predating the record adopts it without touching anything"
rm -rf "$d"
mkdir -p "$d/pi/agent/skills/legacy"
printf 'pre-existing user content\n' >"$d/pi/agent/skills/legacy/SKILL.md"
sum_before="$(sha256sum "$d/pi/agent/skills/legacy/SKILL.md" | cut -d' ' -f1)"
mkres 1.0.0 "v1 content"
run_sync >/dev/null 2>&1
sum_after="$(sha256sum "$d/pi/agent/skills/legacy/SKILL.md" | cut -d' ' -f1)"
chk "pre-existing file keeps its content" '[ "$sum_before" = "$sum_after" ]'
# The file was there before Mash ever kept a record, so Mash cannot vouch for it
# and must not claim it. Files this run created are new and are recorded.
chk "pre-existing file is not claimed" '! rec_has pi/agent/skills/legacy/SKILL.md'
chk "newly seeded files are claimed" 'rec_has pi/agent/skills/demo/SKILL.md'

echo "-- a corrupt record is rebuilt rather than aborting the launch"
printf 'not json' >"$record"
run_sync >/dev/null 2>&1
chk "launch survived" '[ -f "$record" ]'
chk "record is valid again" 'python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$record"'

echo "-- a build with no VERSION never deletes anything"
mkres "x" "no version"
: >"$res/VERSION"
run_sync >/dev/null 2>&1
chk "files still present" '[ -f "$d/pi/agent/skills/legacy/SKILL.md" ]'

# Record keys are user-writable data, not authority to delete arbitrary paths.
echo "-- malformed record paths cannot escape ~/.mash"
mkdir -p "$tmp/outside"
printf 'must stay\n' >"$tmp/outside/sentinel"
python3 - "$record" "$tmp/outside/sentinel" <<'PY'
import hashlib, json, sys
record, path = sys.argv[1:]
h = hashlib.sha256(open(path, "rb").read()).hexdigest()
json.dump({"version": "1.1.0", "files": {"../outside/sentinel": h}}, open(record, "w"))
PY
mkres 1.2.0 "safe"
run_sync >/dev/null 2>&1
chk "outside file survives" 'grep -qx "must stay" "$tmp/outside/sentinel"'

echo "-- a symlinked state directory outside ~/.mash is refused"
rm -rf "$d/local"
ln -s "$tmp/outside" "$d/local"
mkres 1.3.0 "v4 content"
run_sync >/dev/null 2>&1
chk "external state untouched" '[ ! -e "$tmp/outside/state/seeded.json" ]'
chk "external sentinel untouched" 'grep -qx "must stay" "$tmp/outside/sentinel"'

echo
if [ "$failures" -eq 0 ]; then
  echo "test_seed_ownership: PASSED"
  exit 0
fi
echo "test_seed_ownership: FAILED ($failures problem(s))"
exit 1
