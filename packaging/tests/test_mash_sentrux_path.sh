#!/bin/bash
# Sentrux must be given an absolute scan path.
#
# `sentrux mcp` is one long-lived server with its own working directory, so a
# relative path is resolved there rather than against the pane or the repository
# the agent is discussing. Confirmed against sentrux 0.5.7: a server started in
# /tmp answers scan {path: "."} with /tmp's 4448 files and no error at all, so a
# plan's architecture baseline silently describes the wrong tree.
#
# The shipped skill therefore must not teach `.`; mash_rewrite_skill_paths
# replaces that guidance at build time and mash_install_skills refuses to ship
# a copy that still carries it.
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

# The stock wording, as the Mash Programming Skills checkout ships it.
skills="$tmp/pi/skills/mash-sentrux"
mkdir -p "$skills"
cat >"$skills/SKILL.md" <<'EOF'
```bash
# From the workspace root (.), not a subdirectory such as src/.
sentrux gate --save .                    # once: saves .sentrux/baseline.json
sentrux gate .                           # after edits: compares baseline
```

## Repository scope

The application repository is the workspace root itself. All Sentrux commands run relative to the workspace root directory (e.g., `.`).

1. **Workspace root** is the single scan target.

Use one key for the actual scan root (typically `"."`). Use a child path only when the tool response explicitly scopes the repository there.

```json
{
  "repos": {
    ".": {
      "quality_signal": 6772
    }
  }
}
```

```json
{
  "sessions": {
    ".": {
      "pass": true
    }
  }
}
```

| Repo | Session | Signal | Test gaps |
| . | pass (6772 → 6810) | equality | src/.../handler.ts |

```json
"sentruxSessions": {
  ".": "started"
}
```
EOF

mkdir -p "$tmp/res/python/bin"
ln -s "$(python3 -c 'import sys; print(sys.executable)')" "$tmp/res/python/bin/python3"
(
	# shellcheck source=../carry.sh
	source "$root/packaging/carry.sh"
	MASH_RES_ROOT="$tmp/res" mash_rewrite_skill_paths "$tmp/pi"
)
out="$skills/SKILL.md"

grep -q 'run relative to the workspace root directory' "$out" &&
	fail "the relative-path instruction survived" || ok "the relative-path instruction is gone"
grep -q 'absolute path' "$out" &&
	ok "an absolute path is required instead" || fail "no absolute-path instruction"
grep -q 'git rev-parse --show-toplevel' "$out" &&
	ok "the workspace root is resolvable by command" || fail "no way to resolve the root"
grep -q 'typically `"\."`' "$out" &&
	fail "the artifact key still defaults to '.'" || ok "the artifact key is not '.'"
# The JSON examples are what an agent copies when writing the artifact.
if grep -qE '^\s+"\.":' "$out"; then
	fail "a JSON example still keys on '.': $(grep -nE '^\s+"\.":' "$out" | head -1)"
else
	ok "no JSON example keys on '.'"
fi
grep -q '^| \. |' "$out" && fail "the review table still shows '.'" || ok "the review table shows a path"
# The headless fallback runs in a shell, where `.` is the caller's directory --
# correct only by accident, and wrong from a subdirectory.
grep -qE '^sentrux gate (--save )?\.( |$)' "$out" &&
	fail "a gate command still passes '.'" || ok "gate commands name the root explicitly"

# The build must refuse a skill that still carries the old guidance.
guard() {
	grep -qE 'run relative to the workspace root|typically `"\."`' "$1"
}
guard "$out" && fail "guard would pass unrewritten text" || ok "guard rejects nothing after a clean rewrite"
printf 'All Sentrux commands run relative to the workspace root directory (e.g., `.`).\n' >"$tmp/stale.md"
guard "$tmp/stale.md" && ok "guard catches the stock wording" || fail "guard missed the stock wording"

if [ "$failures" -ne 0 ]; then
	printf '\ntest_mash_sentrux_path: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf '\ntest_mash_sentrux_path: PASSED\n'
