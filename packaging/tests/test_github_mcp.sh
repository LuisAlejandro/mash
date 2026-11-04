#!/bin/bash
# Registration and deferred authorization must use Mash's own stored login.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/packaging/launch-common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
check() {
  local msg="$1"
  shift
  if "$@"; then printf 'ok   - %s\n' "$msg"; pass=$((pass + 1));
  else printf 'FAIL - %s\n' "$msg"; fail=$((fail + 1)); fi
}

helper="$root/packaging/helpers/mash-github-mcp"
d="$tmp/Mash data's folder"
mcp="$d/pi/agent/mcp.json"
hosts="$d/config/gh/hosts.yml"
fake="$tmp/fake"
mkdir -p "$fake" "$d/pi/agent" "$d/config/gh"
cat >"$fake/gh" <<'FAKE'
#!/bin/sh
printf called >>"$GH_CALL_RECORD"
printf 'gho_personal_keychain_fixture\n'
FAKE
chmod +x "$fake/gh"
run() {
  env -i HOME="$tmp" PATH="$fake:/usr/bin:/bin" GH_CALL_RECORD="$tmp/gh-calls" \
    GH_TOKEN=gho_inherited_fixture GITHUB_TOKEN=gho_other_inherited_fixture bash "$helper" "$d"
}
resolve() {
  env -i HOME="$tmp" PATH="$fake:/usr/bin:/bin" GH_CALL_RECORD="$tmp/gh-calls" \
    GH_TOKEN=gho_inherited_fixture sh -c "${header#!}"
}
servers() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["mcpServers"])))' "$mcp"; }
github() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["mcpServers"].get("github")))' "$mcp"; }
own_login() { printf 'github.com:\n    users:\n        fixture:\n            oauth_token: %s\n    oauth_token: %s\n    user: fixture\n' "$1" "$1" >"$hosts"; }

printf '{"mcpServers":{"context7":{"type":"http","url":"https://mcp.context7.com/mcp"}}}\n' >"$mcp"
chmod 600 "$mcp"
run
check "personal keychain fallback without Mash login adds no server" test "$(servers)" = context7
check "registration never asks gh for a fallback token" test ! -e "$tmp/gh-calls"

own_login gho_owned_fixture
run
check "Mash-owned sign-in adds the GitHub server" test "$(servers)" = "context7 github"
check "GitHub remote endpoint is preserved" grep -q 'api.githubcopilot.com/mcp' "$mcp"
check "no credential is persisted in MCP JSON" python3 - "$mcp" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert all(secret not in text for secret in ('gho_owned_fixture','gho_personal_keychain_fixture','gho_inherited_fixture'))
PY
check "MCP file stays private" test "$(mash_file_mode "$mcp")" = 600
header="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcpServers"]["github"]["headers"]["Authorization"])' "$mcp")"
check "deferred header uses the current owned token with quoted paths" test "$(resolve)" = "Bearer gho_owned_fixture"
own_login gho_rotated_fixture
check "the existing header observes token rotation" test "$(resolve)" = "Bearer gho_rotated_fixture"
before="$(cat "$mcp")"
run
check "registration remains idempotent after rotation" test "$(cat "$mcp")" = "$before"
rm "$hosts"
check "old header resolves empty after sign-out, without keychain fallback" test -z "$(resolve)"
run
check "sign-out removes only Mash's GitHub entry" test "$(servers)" = context7

# Unsupported, ambiguous or foreign state never counts as a Mash github.com token.
for kind in tokenless foreign nested duplicate duplicate-host malformed fifo; do
  case "$kind" in
    tokenless) printf 'github.com:\n    user: fixture\n' >"$hosts" ;;
    foreign) printf 'example.org:\n    oauth_token: gho_foreign_fixture\n' >"$hosts" ;;
    nested) printf 'github.com:\n    users:\n        another:\n            oauth_token: gho_nested_fixture\n    user: fixture\n' >"$hosts" ;;
    duplicate) printf 'github.com:\n    oauth_token: gho_first_fixture\n    oauth_token: gho_second_fixture\n' >"$hosts" ;;
    duplicate-host) printf 'github.com:\n    oauth_token: gho_first_fixture\ngithub.com:\n    oauth_token: gho_second_fixture\n' >"$hosts" ;;
    fifo) rm -f "$hosts"; mkfifo "$hosts" ;;
    malformed) printf 'github.com: [not a host mapping]\n    oauth_token: gho_malformed_fixture\n' >"$hosts" ;;
  esac
  run
  check "$kind hosts state adds no GitHub entry" test "$(servers)" = context7
  check "$kind hosts state resolves no bearer" test -z "$(resolve)"
  rm -f "$hosts"
done

# gh emits literal scalars; select only the github.com top-level value.
printf 'example.org:\n    oauth_token: gho_foreign_fixture\ngithub.com:\n    oauth_token: "gho_quoted_fixture"\n    user: fixture\n' >"$hosts"
run
check "quoted owned token is selected instead of another host" test "$(resolve)" = "Bearer gho_quoted_fixture"
printf "github.com:\n    oauth_token: 'gho_single_quoted_fixture'\n" >"$hosts"
check "single-quoted literal is supported" test "$(resolve)" = "Bearer gho_single_quoted_fixture"
rm "$hosts"
printf 'github.com:\n    oauth_token: gho_symlink_fixture\n' >"$tmp/outside-hosts"
ln -s "$tmp/outside-hosts" "$hosts"
run
check "symlinked hosts are not a Mash login" test "$(servers)" = context7
check "symlinked hosts resolve no bearer" test -z "$(resolve)"
rm "$hosts"
own_login gho_owned_fixture
mv "$d/config/gh" "$tmp/own-gh"
ln -s "$tmp/own-gh" "$d/config/gh"
run
check "symlinked gh directory is not a Mash login" test "$(servers)" = context7
check "symlinked gh directory resolves no bearer" test -z "$(resolve)"
rm "$d/config/gh"
mv "$tmp/own-gh" "$d/config/gh"
check "no token-output gh command was invoked" test ! -e "$tmp/gh-calls"

# A hard link is another name for the same inode: the personal hosts.yml linked
# into Mash's tree would pass a symlink check alone.
rm -f "$hosts"
printf 'github.com:\n    oauth_token: gho_hardlinked_fixture\n' >"$tmp/personal-hosts.yml"
ln "$tmp/personal-hosts.yml" "$hosts"
run
check "hard-linked personal hosts adds no GitHub entry" test "$(servers)" = context7
check "hard-linked personal hosts resolves no bearer" test -z "$(resolve)"
rm -f "$hosts"
own_login gho_owned_fixture

python3 - "$mcp" <<'PY'
import json,sys
p=sys.argv[1]; config=json.load(open(p)); config['mcpServers']['github']={'command':'my-github-mcp'}
json.dump(config,open(p,'w'),indent=2)
PY
run
check "user-defined server stays untouched while signed in" test "$(github)" = '{"command": "my-github-mcp"}'
rm "$hosts"
run
check "user-defined server stays untouched while signed out" test "$(github)" = '{"command": "my-github-mcp"}'
printf '{ not json' >"$mcp"
run
check "invalid MCP JSON stays unchanged" test "$(cat "$mcp")" = '{ not json'
rm "$mcp"
run
check "missing MCP JSON is not created" test ! -e "$mcp"
check "header-only mode stays empty without its credential" test -z "$(resolve)"
own_login gho_owned_fixture
check "header resolution does not depend on an MCP JSON file" test "$(resolve)" = "Bearer gho_owned_fixture"
mkfifo "$mcp"
run
check "nonregular MCP configuration is refused without opening it" test -p "$mcp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
