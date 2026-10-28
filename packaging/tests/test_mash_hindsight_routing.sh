#!/bin/bash
# Mash's Hindsight commands must reach Mash's daemon, not the owner's.
#
# Mash never changes HOME, so the skills' stock `${HOME}/.local/bin` and
# `${HOME}/.hindsight/embed` name the owner's install and config. Two pieces
# keep Mash sessions on Mash's own daemon:
#   - helpers/hindsight-embed runs Mash's install with HOME set to the data
#     folder;
#   - mash_rewrite_skill_paths strips the owner-pointing lines from the staged
#     skills, so the wrapper on MASH_BIN is what `hindsight-embed` resolves to.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
ok() { printf 'ok    %s\n' "$1"; }
fail() {
	printf 'FAIL  %s\n' "$1" >&2
	failures=$((failures + 1))
}

# --- wrapper -----------------------------------------------------------------
data="$tmp/data"
owner="$tmp/owner"
mkdir -p "$data/.local/bin" "$owner/.local/bin"
# Stand-ins for both installs. Each reports which one ran and the HOME it saw.
cat >"$data/.local/bin/hindsight-embed" <<'EOF'
#!/bin/sh
printf 'mash|%s|%s|%s\n' "$HOME" "$HF_HOME" "$*"
EOF
cat >"$owner/.local/bin/hindsight-embed" <<'EOF'
#!/bin/sh
printf 'owner|%s\n' "$HOME"
EOF
chmod 755 "$data/.local/bin/hindsight-embed" "$owner/.local/bin/hindsight-embed"
wrapper="$root/packaging/helpers/hindsight-embed"

# The owner's ~/.local/bin is on PATH ahead of everything, the worst case.
got="$(env -i HOME="$owner" PATH="$owner/.local/bin:/usr/bin:/bin" \
	MASH_DATA_DIR="$data" bash "$wrapper" memory recall mash q)"
[ "$(printf '%s' "$got" | cut -d'|' -f1)" = mash ] &&
	ok "wrapper runs Mash's install, not the owner's" || fail "wrapper ran: $got"
[ "$(printf '%s' "$got" | cut -d'|' -f2)" = "$data" ] &&
	ok "wrapper sets HOME to the data folder" || fail "wrapper HOME: $got"
[ "$(printf '%s' "$got" | cut -d'|' -f3)" = "$data/cache/huggingface" ] &&
	ok "wrapper keeps the model cache in the data folder" || fail "wrapper HF_HOME: $got"
[ "$(printf '%s' "$got" | cut -d'|' -f4)" = "memory recall mash q" ] &&
	ok "wrapper passes arguments through" || fail "wrapper args: $got"

# The agent directory is enough to find the data folder (the warm-start rule).
mkdir -p "$data/pi/agent"
got="$(env -i HOME="$owner" PATH=/usr/bin:/bin \
	PI_CODING_AGENT_DIR="$data/pi/agent" bash "$wrapper" daemon status)"
[ "$(printf '%s' "$got" | cut -d'|' -f1)" = mash ] &&
	ok "wrapper derives the data folder from PI_CODING_AGENT_DIR" || fail "derive: $got"

# Outside Mash, or before the install, it refuses rather than falling through
# to the owner's copy.
if env -i HOME="$owner" PATH="$owner/.local/bin:/usr/bin:/bin" \
	bash "$wrapper" daemon status >/dev/null 2>&1; then
	fail "wrapper ran with no Mash data folder"
else
	ok "wrapper refuses outside a Mash session"
fi
rm "$data/.local/bin/hindsight-embed"
if env -i HOME="$owner" PATH="$owner/.local/bin:/usr/bin:/bin" \
	MASH_DATA_DIR="$data" bash "$wrapper" daemon status >/dev/null 2>&1; then
	fail "wrapper fell back to the owner's install"
else
	ok "wrapper refuses when Mash's Hindsight is not installed"
fi

# --- skill rewrite -----------------------------------------------------------
# The stock text, as the Mash Programming Skills checkout writes it.
skills="$tmp/pi/skills"
mkdir -p "$skills/mash-hindsight" "$skills/mash-work" "$skills/mash-dogfood"
cat >"$skills/mash-hindsight/SKILL.md" <<'EOF'
```bash
export PATH="${HOME}/.local/bin:${PATH}"
hindsight-embed daemon status
```

```bash
export PATH="${HOME}/.local/bin:${PATH}"
port="$(sed -n 's/^HINDSIGHT_API_PORT=\([0-9][0-9]*\).*/\1/p' "${HOME}/.hindsight/embed" | tail -1)"
port="${port:-8888}"
curl -fsS -m 2 "http://127.0.0.1:${port}/version"
```
EOF
printf '2. Run its availability check — daemon status **and** the `/version` fingerprint (prepend `~/.local/bin` to PATH)\n' \
	>"$skills/mash-work/SKILL.md"
printf 'Run the availability check (daemon status **and** the `/version` fingerprint; PATH includes `${HOME}/.local/bin`); if it passes\n' \
	>"$skills/mash-dogfood/SKILL.md"

# The real function, with the bundled-python lookup pointed at this host's.
# A Mash pane's python3 is a relative shim, so resolve the real interpreter.
mkdir -p "$tmp/res/python/bin"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/res/python/bin/python3"
(
	# shellcheck source=../carry.sh
	source "$root/packaging/carry.sh"
	MASH_RES_ROOT="$tmp/res" mash_rewrite_skill_paths "$tmp/pi"
)

if grep -rqE '\$\{?HOME\}?/\.local/bin|~/\.local/bin' "$skills"; then
	fail "a skill still prepends the owner's ~/.local/bin: $(grep -rnE 'local/bin' "$skills")"
else
	ok "no skill puts the owner's ~/.local/bin on PATH"
fi
if grep -rq '\${HOME}/.hindsight/' "$skills"; then
	fail "a skill still reads the owner's ~/.hindsight"
else
	ok "no skill reads the owner's ~/.hindsight"
fi
grep -q '"${MASH_DATA_DIR:-$HOME/.mash}/.hindsight/embed"' "$skills/mash-hindsight/SKILL.md" &&
	ok "the fingerprint reads Mash's embed config" || fail "fingerprint config path not rewritten"
grep -q 'port="${port:-8998}"' "$skills/mash-hindsight/SKILL.md" &&
	ok "the fingerprint falls back to Mash's port" || fail "fingerprint port fallback not rewritten"
grep -q 'hindsight-embed daemon status' "$skills/mash-hindsight/SKILL.md" &&
	ok "the commands themselves are untouched" || fail "a hindsight-embed command was lost"

# The rewritten fingerprint must actually resolve Mash's port from Mash's file.
mkdir -p "$data/.hindsight"
printf 'HINDSIGHT_API_PORT=8998\n' >"$data/.hindsight/embed"
printf 'HINDSIGHT_API_PORT=8898\n' >"$owner/.hindsight-embed-decoy"
port_line="$(grep '^port="\$(sed' "$skills/mash-hindsight/SKILL.md")"
got="$(env -i HOME="$owner" MASH_DATA_DIR="$data" PATH=/usr/bin:/bin \
	bash -c "$port_line; printf '%s' \"\$port\"")"
[ "$got" = 8998 ] && ok "the fingerprint resolves Mash's port" || fail "fingerprint resolved port '$got'"

if [ "$failures" -ne 0 ]; then
	printf '\ntest_mash_hindsight_routing: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf '\ntest_mash_hindsight_routing: PASSED\n'
