#!/bin/bash
# GitHub MCP is registered only for a Mash whose isolated gh sign-in works, and
# never with a token written into mcp.json.
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../packaging/launch-common.sh
. "$root/packaging/launch-common.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
check() { # check MSG CMD... -- record a pass when CMD succeeds
  local msg="$1"
  shift
  if "$@"; then
    printf 'ok   - %s\n' "$msg"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$msg"
    fail=$((fail + 1))
  fi
}

helper="$root/packaging/helpers/mash-github-mcp"
d="$tmp/data"
mcp="$d/pi/agent/mcp.json"
fake="$tmp/fake"
mkdir -p "$fake" "$d/pi/agent" "$d/config/gh"
# A gh that answers only for Mash's own config dir, so a test also proves the
# helper asks the isolated sign-in rather than an inherited one.
cat >"$fake/gh" <<'FAKE'
#!/bin/bash
[ "${FAKE_SIGNED_IN:-1}" = 1 ] && [ "$GH_CONFIG_DIR" = "$EXPECT_GH_DIR" ] || exit 1
[ "$1 $2" = "auth token" ] && echo gho_faketoken
FAKE
chmod +x "$fake/gh"

run() { # run [VAR=value...]
  env -i HOME="$tmp" PATH="$fake:/usr/bin:/bin" EXPECT_GH_DIR="$d/config/gh" \
    GH_TOKEN=inherited-should-not-matter "$@" bash "$helper" "$d"
}
servers() { python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["mcpServers"])))' "$mcp"; }
github() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["mcpServers"].get("github")))' "$mcp"; }

printf '{\n  "mcpServers": {\n    "context7": {"type": "http", "url": "https://mcp.context7.com/mcp"}\n  }\n}\n' >"$mcp"
chmod 600 "$mcp"

# --- not signed in: nothing is added -------------------------------------------
run FAKE_SIGNED_IN=0
check "no sign-in adds no GitHub server" test "$(servers)" = "context7"

# --- signed in: added, token-free, other servers kept ---------------------------
run
check "sign-in adds the GitHub server" test "$(servers)" = "context7 github"
check "the server is GitHub's remote MCP" grep -q 'api.githubcopilot.com/mcp' "$mcp"
check "no token is written to mcp.json" bash -c "! grep -q gho_faketoken '$mcp'"
check "the header asks Mash's own gh config" grep -q "GH_CONFIG_DIR=$d/config/gh" "$mcp"
check "inherited GitHub tokens are ignored" grep -q 'env -u GH_TOKEN -u GITHUB_TOKEN' "$mcp"
# mash_file_mode, not an inline stat fallback: GNU stat reads -f as
# --file-system and prints a report on stdout before failing, so the fallback
# value lands after it and the comparison can never match on Linux.
check "file permissions are kept private" test "$(mash_file_mode "$mcp")" = 600

# --- the generated header resolves to a bearer token ---------------------------
header="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcpServers"]["github"]["headers"]["Authorization"])' "$mcp")"
resolved="$(env -i HOME="$tmp" PATH="$fake:/usr/bin:/bin" EXPECT_GH_DIR="$d/config/gh" GH_TOKEN=x \
  sh -c "${header#!}")"
check "the header resolves to the Mash sign-in token" test "$resolved" = "Bearer gho_faketoken"
signed_out="$(env -i HOME="$tmp" PATH="$fake:/usr/bin:/bin" FAKE_SIGNED_IN=0 sh -c "${header#!}")"
check "a lost sign-in resolves to nothing, not a bare Bearer" test -z "$signed_out"

# --- idempotent ------------------------------------------------------------------
before="$(cat "$mcp")"
run
check "a second launch changes nothing" test "$(cat "$mcp")" = "$before"

# --- signing out removes only Mash's own entry -----------------------------------
run FAKE_SIGNED_IN=0
check "sign-out removes Mash's GitHub server" test "$(servers)" = "context7"

# --- a user's own github entry is never touched -----------------------------------
python3 - "$mcp" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["mcpServers"]["github"] = {"command": "my-github-mcp"}
json.dump(d, open(p, "w"), indent=2)
PY
run
check "a user-defined github server is kept when signed in" test "$(github)" = '{"command": "my-github-mcp"}'
run FAKE_SIGNED_IN=0
check "a user-defined github server is kept when signed out" test "$(github)" = '{"command": "my-github-mcp"}'

# --- broken or missing files are left alone ---------------------------------------
printf '{ not json' >"$mcp"
run
check "an unreadable mcp.json is not rewritten" test "$(cat "$mcp")" = '{ not json'
rm -f "$mcp"
run
check "a missing mcp.json is not created" test ! -e "$mcp"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
