#!/usr/bin/env bash
# mash_isolate turns setup/language into the locale and catalog language of every
# Mash process (U3, R3, R5, R14; AE2, AE5, AE8).
#
# The file holds one `language=<code>` line, like setup/keybindings-mode. The code
# decides LANG, MASH_LANGUAGE and MASH_I18N_DIR, clears the LC_* variables that
# would otherwise keep part of the process on the inherited locale, and falls back
# to C.UTF-8 plus LANGUAGE on a Linux host that does not have the locale installed.
# A code Mash does not ship reads as absent and never breaks a launch. mash-t then
# reads the catalogs in that language, with English as the runtime fallback.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/lib.sh"
mash_t="$root/helpers/mash-t"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app/bin" "$tmp/app/i18n/messages"

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

value() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

assert_value() {
	local out="$1" key="$2" want="$3" got
	got="$(value "$out" "$key")"
	[ "$got" = "$want" ] ||
		fail "expected $key=$want, got ${got:-<unset>}
$out"
}

assert_absent() {
	local out="$1" key="$2"
	case "
$out
" in
	*"
$key="*) fail "expected $key unset
$out" ;;
	esac
}

# Record a language, the way the wizard and a hand edit both do.
set_language() {
	local home="$1" code="$2"
	mkdir -p "$home/.mash/setup" "$home/.mash/local/state" "$home/.mash/run"
	printf 'language=%s\n' "$code" >"$home/.mash/setup/language"
}

# Run mash_isolate the way a pane does, then print the environment it produced.
#
# $1 is the scratch home and $2 the PATH for the isolated process -- a test that
# stubs `locale` needs its own directory ahead of /usr/bin. The remaining
# arguments are `env` assignments, so a test can hand a locale in and see which
# parts of it survive. The library is copied to an app-shaped bin/ so the staged
# i18n directory has its bundle layout.
isolate_env() {
	local home="$1" path="$2"
	shift 2
	cp "$lib" "$tmp/app/bin/lib.sh"
	env -i HOME="$home" PATH="$path" MASH_BIN="$tmp/app/bin" "$@" \
		bash -c 'set -euo pipefail; source "$1"; mash_isolate "$2" pane; env' \
		_ "$tmp/app/bin/lib.sh" "$home"
}

# Same, but run one command in the environment instead of printing all of it.
isolate_run() {
	local home="$1" path="$2"
	shift 2
	cp "$lib" "$tmp/app/bin/lib.sh"
	env -i HOME="$home" PATH="$path" MASH_BIN="$tmp/app/bin" \
		bash -c 'set -euo pipefail; source "$1"; mash_isolate "$2" pane; shift 2; exec "$@"' \
		_ "$tmp/app/bin/lib.sh" "$home" "$@"
}

[ -f "$root/i18n/languages.json" ] || fail "missing $root/i18n/languages.json"

locales_available="$({ locale -a || true; } 2>/dev/null)"

# de: the chosen language, and no LC_* left over from the environment the app
# was started from. Where the host ships de_DE.UTF-8, LANG names it; on Linux
# without that locale, AE8 applies (C.UTF-8 + LANGUAGE) like the vi stub below.
home="$tmp/home-de"
set_language "$home" de
out="$(isolate_env "$home" "/usr/bin:/bin" \
	LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=de_DE.UTF-8)"
if printf '%s\n' "$locales_available" | grep -iE '^de_DE\.utf-?8$' >/dev/null; then
	assert_value "$out" LANG de_DE.UTF-8
	assert_absent "$out" LANGUAGE
else
	case "$(uname -s)" in
	Linux)
		assert_value "$out" LANG C.UTF-8
		assert_value "$out" LANGUAGE de_DE
		;;
	*) fail "expected de_DE.UTF-8 on this host, but locale -a lists none" ;;
	esac
fi
assert_value "$out" MASH_LANGUAGE de
assert_value "$out" MASH_I18N_DIR "$tmp/app/i18n"
assert_absent "$out" LC_ALL
assert_absent "$out" LC_TIME
assert_absent "$out" LC_NUMERIC

# AE5: the locale is real, not just an environment string. Only where the host
# actually ships it -- a Linux image without de_DE.UTF-8 cannot print German day
# names, and that case is AE8's fallback below, not this one.
if printf '%s\n' "$locales_available" | grep -iE '^de_DE\.utf-?8$' >/dev/null; then
	home="$tmp/home-date"
	set_language "$home" de
	epoch=1700000000
	case "$(uname -s)" in
	Darwin) date_args=(-r "$epoch") ;;
	*) date_args=(-d "@$epoch") ;;
	esac
	day="$(isolate_run "$home" "/usr/bin:/bin" date "${date_args[@]}" +%A)"
	[ "$day" = "Dienstag" ] || fail "expected a German day name under language=de, got $day"
else
	printf 'SKIP  date prints German day names: no de_DE.UTF-8 on this host\n'
fi

# No setup/language -- an install from before the wizard asked -- leaves the
# environment exactly as the user had it.
home="$tmp/home-none"
mkdir -p "$home/.mash/run"
out="$(isolate_env "$home" "/usr/bin:/bin" \
	LANG=es_MX.UTF-8 LC_ALL=es_MX.UTF-8 LC_TIME=es_MX.UTF-8)"
assert_value "$out" LANG es_MX.UTF-8
assert_value "$out" LC_ALL es_MX.UTF-8
assert_value "$out" LC_TIME es_MX.UTF-8
assert_absent "$out" MASH_LANGUAGE

# No language recorded (an install from before the wizard asked): the locale is
# left as inherited and English is the default, but the catalogs stay reachable,
# so Pi extensions show their English text instead of raw message keys.
home="$tmp/home-none-catalogs"
mkdir -p "$home/.mash/run" "$tmp/app/i18n"
out="$(isolate_env "$home" "/usr/bin:/bin" LANG=es_MX.UTF-8 LC_ALL=es_MX.UTF-8)"
assert_value "$out" LANG es_MX.UTF-8
assert_value "$out" LC_ALL es_MX.UTF-8
assert_absent "$out" MASH_LANGUAGE
assert_value "$out" MASH_I18N_DIR "$tmp/app/i18n"

# A code Mash does not ship behaves like no file: the launch still works, nothing
# is exported, and the reason lands in the launch log once.
home="$tmp/home-unknown"
set_language "$home" xx
out="$(isolate_env "$home" "/usr/bin:/bin" LANG=es_MX.UTF-8 LC_ALL=es_MX.UTF-8)"
assert_value "$out" LANG es_MX.UTF-8
assert_value "$out" LC_ALL es_MX.UTF-8
assert_absent "$out" MASH_LANGUAGE
log="$home/.mash/local/state/mash-launch.log"
[ -f "$log" ] || fail "unknown language wrote no launch log line"
grep -q 'xx is not a language Mash ships' "$log" ||
	fail "launch log does not name the unknown code:
$(cat "$log")"
# A second call -- the next pane -- must not add a duplicate line.
isolate_env "$home" "/usr/bin:/bin" >/dev/null
[ "$(grep -c 'xx is not a language Mash ships' "$log")" = 1 ] ||
	fail "the unknown-code line was logged more than once"

# AE8: on Linux without the locale installed, LANG becomes a locale the system
# can always set and LANGUAGE carries the choice, so the shell warns about
# nothing while Mash's own text still follows the language.
stub="$tmp/stub-locale"
mkdir -p "$stub"
cat >"$stub/locale" <<'EOF'
#!/bin/sh
# The locales a minimal Linux image really has: none of the wizard's.
printf 'C\nC.utf8\nPOSIX\nen_US.utf8\n'
EOF
chmod 755 "$stub/locale"
linux_path="$stub:/usr/bin:/bin"

home="$tmp/home-vi-missing"
set_language "$home" vi
out="$(isolate_env "$home" "$linux_path" MASH_UNAME=Linux LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8)"
assert_value "$out" LANG C.UTF-8
assert_value "$out" LANGUAGE vi_VN
assert_value "$out" MASH_LANGUAGE vi
assert_absent "$out" LC_ALL

# LANGUAGE is gettext's ll_CC, not Mash's code: Ghostty ships pt_BR, not pt-BR.
home="$tmp/home-pt-missing"
set_language "$home" pt-BR
out="$(isolate_env "$home" "$linux_path" MASH_UNAME=Linux LANG=en_US.UTF-8)"
assert_value "$out" LANGUAGE pt_BR
assert_value "$out" MASH_LANGUAGE pt-BR

# The point of that fallback: a non-interactive shell started under it says
# nothing about a locale it cannot set.
stderr="$(isolate_run "$home" "$linux_path" bash -c 'true' 2>&1 >/dev/null)" ||
	fail "bash failed under the missing-locale fallback"
[ -z "$stderr" ] || fail "bash complained about the locale:
$stderr"

# The same language on a host that has the locale keeps the real LANG: the
# fallback must not fire, or every Linux user would lose regional formatting.
present="$tmp/stub-locale-present"
mkdir -p "$present"
cat >"$present/locale" <<'EOF'
#!/bin/sh
printf 'C\nC.utf8\nPOSIX\nvi_VN.utf8\n'
EOF
chmod 755 "$present/locale"
home="$tmp/home-vi-present"
set_language "$home" vi
out="$(isolate_env "$home" "$present:/usr/bin:/bin" MASH_UNAME=Linux LANG=en_US.UTF-8)"
assert_value "$out" LANG vi_VN.UTF-8
assert_absent "$out" LANGUAGE

# masm-t reads the catalog in that language, substitutes placeholders, and falls
# back to English for a key a catalog lacks.
i18n="$tmp/i18n"
mkdir -p "$i18n/messages/helpers"
printf '%s\n' '{"helper.example": "Count {count} items", "helper.english-only": "Only in English"}' \
	>"$i18n/messages/helpers/en.json"
printf '%s\n' '{"helper.example": {"text": "Cuenta {count} elementos", "source_hash": "x"}}' \
	>"$i18n/messages/helpers/es.json"

got="$(MASH_I18N_DIR="$i18n" MASH_LANGUAGE=es "$mash_t" helper.example count=3)"
[ "$got" = "Cuenta 3 elementos" ] || fail "expected Spanish with the placeholder substituted, got $got"
got="$(MASH_I18N_DIR="$i18n" MASH_LANGUAGE=es "$mash_t" helper.english-only)"
[ "$got" = "Only in English" ] || fail "expected the English fallback, got $got"
got="$(MASH_I18N_DIR="$i18n" "$mash_t" helper.example count=3)"
[ "$got" = "Count 3 items" ] || fail "expected English when MASH_LANGUAGE is unset, got $got"
got="$(MASH_I18N_DIR="$i18n" MASH_LANGUAGE=es "$mash_t" helper.example)"
[ "$got" = "Cuenta {count} elementos" ] ||
	fail "an unsubstituted placeholder must stay visible, got $got"
if got="$(MASH_I18N_DIR="$i18n" MASH_LANGUAGE=es "$mash_t" helper.missing 2>"$tmp/missing.err")"; then
	fail "an unknown key must not exit 0"
fi
[ -z "$got" ] || fail "an unknown key must print nothing, got $got"
grep -q 'helper.missing' "$tmp/missing.err" || fail "an unknown key must name itself on stderr"
if MASH_I18N_DIR="$i18n" "$mash_t" helper.example not-a-pair >/dev/null 2>&1; then
	fail "a bare argument must be refused"
fi

# AE2: the pane shell reads setup/language on every start, so a change reaches
# the next pane while Herdr's server keeps running from the earlier launch.
# dscl and getent are stubbed because mash_real_home reads the account database,
# not $HOME, and the pane must be built around the scratch home.
pane_stub="$tmp/stub-pane"
mkdir -p "$pane_stub" "$tmp/pane/bin"
cat >"$pane_stub/dscl" <<'EOF'
#!/bin/sh
case "$*" in
*NFSHomeDirectory*) printf 'NFSHomeDirectory: %s\n' "$HOME" ;;
*UserShell*) printf 'UserShell: /bin/sh\n' ;;
*) exit 1 ;;
esac
EOF
cat >"$pane_stub/getent" <<'EOF'
#!/bin/sh
printf '%s:x:0:0::%s:/bin/sh\n' "$(id -un)" "$HOME"
EOF
cat >"$pane_stub/account-shell" <<'EOF'
#!/bin/sh
printf 'LANG=%s' "${LANG:-}"
[ -n "${LANGUAGE:-}" ] && printf ' LANGUAGE=%s' "$LANGUAGE"
printf '\n'
EOF
chmod 755 "$pane_stub/dscl" "$pane_stub/getent" "$pane_stub/account-shell"
cp "$root/mash-shell" "$root/lib.sh" "$tmp/pane/bin/"

home="$tmp/home-pane"
set_language "$home" es
pane_lang() {
	env -i HOME="$home" PATH="$pane_stub:/usr/bin:/bin" MASH_BIN="$tmp/pane/bin" \
		MASH_USER_SHELL="$pane_stub/account-shell" bash "$tmp/pane/bin/mash-shell"
}
if printf '%s\n' "$locales_available" | grep -iE '^es_MX\.utf-?8$' >/dev/null; then
	[ "$(pane_lang)" = "LANG=es_MX.UTF-8" ] ||
		fail "a new pane did not pick up language=es: $(pane_lang)"
	set_language "$home" ja
	if printf '%s\n' "$locales_available" | grep -iE '^ja_JP\.utf-?8$' >/dev/null; then
		[ "$(pane_lang)" = "LANG=ja_JP.UTF-8" ] ||
			fail "a pane kept the old language after the file changed: $(pane_lang)"
	else
		case "$(uname -s)" in
		Linux)
			[ "$(pane_lang)" = "LANG=C.UTF-8 LANGUAGE=ja_JP" ] ||
				fail "a pane kept the old language after the file changed: $(pane_lang)"
			;;
		*) fail "expected ja_JP.UTF-8 on this host, but locale -a lists none" ;;
		esac
	fi
else
	case "$(uname -s)" in
	Linux)
		[ "$(pane_lang)" = "LANG=C.UTF-8 LANGUAGE=es_MX" ] ||
			fail "a new pane did not pick up language=es: $(pane_lang)"
		set_language "$home" ja
		[ "$(pane_lang)" = "LANG=C.UTF-8 LANGUAGE=ja_JP" ] ||
			fail "a pane kept the old language after the file changed: $(pane_lang)"
		;;
	*) fail "expected es_MX.UTF-8 on this host, but locale -a lists none" ;;
	esac
fi

# KTD1: the map lib.sh keeps cannot drift from the language table.
rows=0
while IFS='	' read -r code locale_name; do
	rows=$((rows + 1))
	got="$(bash -c 'source "$1"; mash_language_locale "$2"' _ "$lib" "$code" || true)"
	[ "$got" = "$locale_name" ] ||
		fail "languages.json says $code is $locale_name, lib.sh says ${got:-nothing}"
done < <(python3 - "$root/i18n/languages.json" <<'PY'
import json, sys
for row in json.load(open(sys.argv[1], encoding="utf-8")):
    print(f'{row["code"]}	{row["locale"]}')
PY
)
cases="$(sed -n '/^mash_language_locale()/,/^}/p' "$lib" | grep -c '^  [A-Za-z-]*) printf')"
[ "$cases" = "$rows" ] ||
	fail "lib.sh maps $cases language(s), languages.json names $rows"

echo "mash language environment: all checks passed"
