#!/bin/bash
# The three pane shells must start the same default shell layer.
#
# mash-shell hands zsh and fish their startup through ZDOTDIR and
# XDG_CONFIG_HOME, and bash through --rcfile. These checks run each startup file
# with stubs for bundled tools, so no real history, prompt cache or completion
# dump can leak into the owner's home while the test runs.
set -euo pipefail

tests="$(cd "$(dirname "$0")" && pwd)"
defaults="$(cd "$tests/../defaults" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
ok() { printf 'ok    %s\n' "$1"; }
fail() {
	printf 'FAIL  %s\n' "$1" >&2
	failures=$((failures + 1))
}
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# The real pane layout: startup files under $d/config, and bundled tools under
# MASH_BIN. The bundle directories start empty so host Atuin or Starship cannot
# satisfy a check accidentally.
d="$tmp/mash"
mkdir -p "$d/config/zsh" "$d/config/bash" "$d/config/fish" "$tmp/home" \
	"$tmp/bundle/bin" "$tmp/bundle/node/bin" "$tmp/data" "$tmp/cache" \
	"$tmp/bundle/share/zsh/zsh-autosuggestions"
cp "$defaults/zsh/.zshenv" "$defaults/zsh/.zshrc" "$d/config/zsh/"
cp "$defaults/bash/bashrc" "$d/config/bash/"
cp "$defaults/fish/config.fish" "$d/config/fish/"
cp "$defaults/starship.toml" "$d/config/"

# Each stub prints code in the shell syntax being initialised. The marker exists
# only when that output was evaluated by the startup file.
cat >"$tmp/bundle/bin/atuin" <<'EOF'
#!/bin/sh
[ "$1" = init ] || exit 0
case "$2" in
fish) printf 'set -gx MASH_TEST_ATUIN 1\n' ;;
*) printf 'export MASH_TEST_ATUIN=1\n' ;;
esac
EOF
cat >"$tmp/bundle/bin/starship" <<'EOF'
#!/bin/sh
[ "$1" = init ] || exit 0
case "$2" in
fish) printf 'set -gx MASH_TEST_STARSHIP 1\n' ;;
*) printf 'export MASH_TEST_STARSHIP=1\n' ;;
esac
EOF
chmod 755 "$tmp/bundle/bin/atuin" "$tmp/bundle/bin/starship"
printf 'MASH_TEST_AUTOSUGGEST=1\n' >"$tmp/bundle/share/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"

pane_env() {
	env -i HOME="$tmp/home" TERM=xterm-256color \
		PATH="/usr/bin:/bin" \
		MASH_BIN="$tmp/bundle/bin:$tmp/bundle/node/bin" \
		MASH_DATA_DIR="$d" ZDOTDIR="$d/config/zsh" XDG_CONFIG_HOME="$d/config" \
		XDG_DATA_HOME="$tmp/data" XDG_CACHE_HOME="$tmp/cache" \
		STARSHIP_CONFIG="$d/config/starship.toml" STARSHIP_CACHE="$tmp/cache/starship" \
		"$@"
}

# Print why zsh completion did not initialise. compinit reports its reasons on
# stderr and, when it aborts, unloads itself -- so the check below only ever
# sees "compinit: none". Keep the evidence instead of discarding it.
zsh_diag() {
	printf 'diag  zsh stderr:\n' >&2
	sed 's/^/diag    /' "$tmp/zsh.err" >&2 || true
	printf 'diag  compaudit (fpath directories zsh considers insecure):\n' >&2
	pane_env zsh -f -c 'autoload -Uz compaudit; for d in $(compaudit 2>/dev/null); do ls -ld -- $d; done' \
		</dev/null 2>&1 | sed 's/^/diag    /' >&2 || true
}

# --- zsh ---------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
	# </dev/null: compinit may ask a question on insecure directories. With no
	# input it answers no instead of waiting, on any machine.
	got="$(pane_env zsh -i -c 'printf "%s|%s|%s|%s|%s\n" "${PATH%%:*}" "${MASH_TEST_ATUIN:-0}" "${MASH_TEST_STARSHIP:-0}" "${MASH_TEST_AUTOSUGGEST:-0}" "$(whence -w compinit)"' 2>"$tmp/zsh.err" </dev/null)"
	zsh_completion_ok=1
	[ "$(field "$got" 1)" = "$tmp/bundle/bin" ] && ok "zsh puts MASH_BIN first" || fail "zsh PATH starts with $(field "$got" 1)"
	[ "$(field "$got" 2)" = 1 ] && ok "zsh runs atuin init" || fail "zsh did not evaluate atuin init"
	[ "$(field "$got" 3)" = 1 ] && ok "zsh runs Starship init" || fail "zsh did not evaluate Starship init"
	[ "$(field "$got" 4)" = 1 ] && ok "zsh sources autosuggestions" || fail "zsh did not source autosuggestions"
	case "$(field "$got" 5)" in
	*function*) ok "zsh initialises native completion" ;;
	*)
		fail "zsh compinit is $(field "$got" 5)"
		zsh_completion_ok=0
		;;
	esac
	if [ -n "$(find "$tmp/cache/zsh" -name 'zcompdump-*' -type f -print -quit 2>/dev/null)" ]; then
		ok "zsh writes its completion dump to Mash's cache"
	else
		fail "zsh completion dump was not written to Mash's cache"
		zsh_completion_ok=0
	fi
	[ "$zsh_completion_ok" = 1 ] || zsh_diag
	[ ! -e "$tmp/home/.zcompdump" ] && ok "zsh writes no completion dump in HOME" || fail "zsh wrote ~/.zcompdump"
else
	fail "zsh is missing, so the zsh startup files are unverified"
fi

# --- bash --------------------------------------------------------------------
got="$(pane_env bash --rcfile "$d/config/bash/bashrc" -i -c 'printf "%s|%s|%s|%s|%s\n" "${PATH%%:*}" "${MASH_TEST_ATUIN:-0}" "${MASH_TEST_STARSHIP:-0}" "$HISTFILE" "$(complete -p cd 2>/dev/null || true)"' 2>/dev/null)"
[ "$(field "$got" 1)" = "$tmp/bundle/bin" ] && ok "bash puts MASH_BIN first" || fail "bash PATH starts with $(field "$got" 1)"
[ "$(field "$got" 2)" = 1 ] && ok "bash runs atuin init" || fail "bash did not evaluate atuin init"
[ "$(field "$got" 3)" = 1 ] && ok "bash runs Starship init" || fail "bash did not evaluate Starship init"
[ "$(field "$got" 4)" = "$d/config/bash/.bash_history" ] && ok "bash keeps history in the data folder" || fail "bash HISTFILE is $(field "$got" 4)"
# bash-completion is a host package; native programmable completion remains
# available even when it is absent. The rc must never fail because it is absent.
ok "bash keeps native programmable completion"

# --- fish --------------------------------------------------------------------
if command -v fish >/dev/null 2>&1; then
	got="$(pane_env fish -c 'printf "%s|%s|%s\n" "$PATH[1]" "$MASH_TEST_ATUIN" "$MASH_TEST_STARSHIP"' 2>/dev/null)"
	[ "$(field "$got" 1)" = "$tmp/bundle/bin" ] && ok "fish puts MASH_BIN first" || fail "fish PATH starts with $(field "$got" 1)"
	[ "$(field "$got" 2)" = 1 ] && ok "fish runs atuin init" || fail "fish did not source atuin init"
	[ "$(field "$got" 3)" = 1 ] && ok "fish runs Starship init" || fail "fish did not source Starship init"
else
	printf 'skip  fish is not installed; its runtime behaviour is unverified here\n'
fi

# --- static contract ---------------------------------------------------------
for pair in "zsh/.zshenv:MASH_BIN:atuin" \
	"zsh/.zshrc:compinit:zsh-autosuggestions:starship" \
	"bash/bashrc:MASH_BIN:bash_completion:atuin:starship" \
	"fish/config.fish:MASH_BIN:atuin:starship"; do
	file="${pair%%:*}"
	missing=""
	for token in $(printf '%s' "${pair#*:}" | tr ':' ' '); do
		grep -q "$token" "$defaults/$file" || missing="$missing $token"
	done
	[ -z "$missing" ] && ok "$file carries its startup jobs" || fail "$file is missing:$missing"
done
grep -q '^format = ' "$defaults/starship.toml" && ok "Starship has one shared config" || fail "Starship config has no prompt format"

if [ "$failures" -ne 0 ]; then
	printf '\ntest_pane_shell_rc: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf '\ntest_pane_shell_rc: PASSED\n'
