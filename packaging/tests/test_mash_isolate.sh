#!/usr/bin/env bash
# mash_isolate must keep a pane's own Herdr identity, because pi's Herdr
# integration and herdr-fresh-pane report the pane's resume command through
# HERDR_ENV/HERDR_PANE_ID. The launch path must still clear it so a Mash started
# from a pane of a personal Herdr cannot attach to that server, and every call
# must point the socket at ~/.mash.
set -euo pipefail

lib="${1:-$(cd "$(dirname "$0")/.." && pwd)/lib.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
# ~/.bun/bin must exist before any run_isolate call: mash_isolate skips host
# directories that are not there, so creating it later would make the
# assertions below pass only against a run that never saw it.
mkdir -p "$home/.mash/run" "$home/.bun/bin"

run_isolate() {
	local mode="${1:-}" shape="${2:-default}" instance="${3:-}" mashbin path
	case "$shape" in
	default)
		mashbin="$tmp/app/bin:$tmp/app/node/bin:$home/.mash/bin"
		path="/usr/bin:/bin"
		;;
	# The shape a pane saw when mash-shell rebuilt MASH_BIN from its own
	# directory alone -- which is what it did before it was fixed -- while
	# Mash's own program directories were still on the inherited PATH further
	# down and no host directory was on it at all. mash_isolate prepends host
	# directories that are missing from PATH, so without an explicit tier order
	# /opt/homebrew/bin landed ahead of Mash's own directories and every pane
	# ran Homebrew's pi (0.99.1) instead of the pinned 1.1.0.
	clobbered)
		mashbin="$home/.mash/bin"
		path="$tmp/app/bin:$tmp/app/node/bin:$home/.mash/bin:/usr/bin:/bin"
		;;
	*)
		printf 'unknown isolate shape: %s\n' "$shape" >&2
		exit 2
		;;
	esac
	env -i \
		HOME="$home" \
		PATH="$path" \
		MASH_BIN="$mashbin" \
		HERDR_ENV="1" \
		HERDR_PANE_ID="w1:p1" \
		HERDR_BIN_PATH="/personal/herdr" \
		HERDR_WORKSPACE_ID="w1" \
		HERDR_TAB_ID="w1:t1" \
		HERDR_SOCKET_PATH="$home/.config/herdr/herdr.sock" \
		HERDR_CLIENT_SOCKET_PATH="$home/.config/herdr/herdr-client.sock" \
		HERDR_CONFIG_PATH="$home/.config/herdr/config.toml" \
		XDG_CONFIG_HOME="$home/.config" \
		${instance:+MASH_INSTANCE="$instance"} \
		bash -c 'source "$1"; mash_isolate "$2" "$3"; env' _ "$lib" "$home" "$mode"
}

assert_value() {
	local out="$1" key="$2" want="$3" got
	got="$(printf '%s\n' "$out" | sed -n "s/^${key}=//p")"
	[ "$got" = "$want" ] || {
		printf 'expected %s=%s, got %s\n%s\n' "$key" "$want" "${got:-<unset>}" "$out" >&2
		exit 1
	}
}

assert_unset() {
	local out="$1" key="$2"
	if printf '%s\n' "$out" | grep -q "^${key}="; then
		printf 'expected %s unset\n%s\n' "$key" "$out" >&2
		exit 1
	fi
}

# Exact element membership, not a substring test. The substring form passed on a
# MANGLED PATH: when MASH_BIN's last entry glued onto the first host directory,
# the string "/Users/me/.mash/bin/opt/homebrew/bin:" still contained
# ":/opt/homebrew/bin:", so the check reported success while /opt/homebrew/bin
# was in fact missing and every Homebrew tool in every pane was gone.
assert_on_path() {
	local out="$1" dir="$2" path
	path="$(printf '%s\n' "$out" | sed -n 's/^PATH=//p')"
	if ! printf '%s' "$path" | tr ':' '\n' | grep -qxF -- "$dir"; then
		printf 'expected %s as a PATH element; got:\n' "$dir" >&2
		printf '%s' "$path" | tr ':' '\n' | sed 's/^/  /' >&2
		exit 1
	fi
}

# No element may be one path glued onto another. A colon-separated list joined
# without its separator produces entries like "/a/bin/opt/homebrew/bin".
assert_no_glued_elements() {
	local out="$1" path elem
	path="$(printf '%s\n' "$out" | sed -n 's/^PATH=//p')"
	while IFS= read -r elem; do
		case "$elem" in
		*bin/*bin*)
			printf 'PATH element looks like a joined path: %s\n' "$elem" >&2
			exit 1
			;;
		esac
	done < <(printf '%s\n' "$path" | tr ':' '\n')
}

pane="$(run_isolate pane)"
assert_value "$pane" HERDR_ENV 1
assert_value "$pane" HERDR_PANE_ID w1:p1
assert_value "$pane" HERDR_BIN_PATH /personal/herdr
assert_value "$pane" HERDR_WORKSPACE_ID w1
assert_value "$pane" HERDR_TAB_ID w1:t1
assert_value "$pane" HERDR_SOCKET_PATH "$home/.mash/run/herdr.sock"
assert_value "$pane" HERDR_CONFIG_PATH "$home/.mash/config/herdr/config.toml"
assert_value "$pane" XDG_CONFIG_HOME "$home/.mash/config"

launch="$(run_isolate)"
assert_unset "$launch" HERDR_ENV
assert_unset "$launch" HERDR_PANE_ID
assert_unset "$launch" HERDR_BIN_PATH
assert_unset "$launch" HERDR_WORKSPACE_ID
assert_unset "$launch" HERDR_TAB_ID
assert_value "$launch" HERDR_SOCKET_PATH "$home/.mash/run/herdr.sock"
assert_value "$launch" HERDR_CONFIG_PATH "$home/.mash/config/herdr/config.toml"

# pi packages the user installs belong to Mash, never to the owner's own pi.
# pi installs under PI_CODING_AGENT_DIR, and a plugin that cannot call pi's
# getAgentDir() falls back to PI_HOME, defaulting to ~/.pi/agent: without it a
# plugin installed in Mash would read and write the owner's own pi. npm caches
# under HOME, which Mash never changes, so the cache is pinned here too.
for out in "$pane" "$launch"; do
	assert_value "$out" PI_CODING_AGENT_DIR "$home/.mash/pi/agent"
	assert_value "$out" PI_HOME "$home/.mash/pi/agent"
	assert_value "$out" npm_config_cache "$home/.mash/cache/npm"
done

# The host directories the wizard's Homebrew tools live in must be on the
# session PATH even when the app was started with a GUI's minimal PATH; the
# sesh preview runs `sh -lc` on that path and fails with exit status 127
# without them. The MASH_BIN entries must survive whole too.
for dir in /opt/homebrew/bin /usr/local/bin; do
	[ -d "$dir" ] || continue
	assert_on_path "$pane" "$dir"
	assert_on_path "$launch" "$dir"
done
# ~/.bun/bin: bun is not a Homebrew package -- the bun installer puts bun and
# bunx there -- so no entry in the hardcoded host list can reach it. A `bun
# install` in a pane writes a program the pane then cannot run by name without
# it. mash_isolate is run under the test's scratch HOME, so the directory it
# must find is that HOME's, and the suite creates it: the assertion tests the
# wiring, not the owner's machine.
assert_on_path "$pane" "$home/.bun/bin"
assert_on_path "$launch" "$home/.bun/bin"
for dir in "$tmp/app/bin" "$tmp/app/node/bin" "$home/.mash/bin"; do
	assert_on_path "$pane" "$dir"
	assert_on_path "$launch" "$dir"
done
assert_no_glued_elements "$pane"
assert_no_glued_elements "$launch"

# Mash's own program directories must lead every host directory mash_isolate
# adds, in both shapes MASH_BIN arrives in. Order is the whole guarantee: each
# bundled program has a host twin (Homebrew carries pi, node, npm, npx,
# python3, fresh, lazygit, lazydocker and pet), so a host directory ahead of
# Mash's runs the wrong version of whichever program the pane starts.
assert_precedes() {
	local out="$1" first="$2" second="$3" path elem i=0 idx_first="" idx_second=""
	path="$(printf '%s\n' "$out" | sed -n 's/^PATH=//p')"
	while IFS= read -r elem; do
		i=$((i + 1))
		[ "$elem" = "$first" ] && [ -z "$idx_first" ] && idx_first="$i"
		[ "$elem" = "$second" ] && [ -z "$idx_second" ] && idx_second="$i"
	done < <(printf '%s\n' "$path" | tr ':' '\n')
	if [ -z "$idx_first" ] || [ -z "$idx_second" ]; then
		printf 'expected both %s and %s as PATH elements; got:\n' "$first" "$second" >&2
		printf '%s' "$path" | tr ':' '\n' | sed 's/^/  /' >&2
		exit 1
	fi
	[ "$idx_first" -lt "$idx_second" ] || {
		printf 'expected %s before %s; got:\n' "$first" "$second" >&2
		printf '%s' "$path" | tr ':' '\n' | sed 's/^/  /' >&2
		exit 1
	}
}

clobbered="$(run_isolate pane clobbered)"
for host in /opt/homebrew/bin /usr/local/bin; do
	[ -d "$host" ] || continue
	for dir in "$tmp/app/bin" "$tmp/app/node/bin" "$home/.mash/bin"; do
		assert_precedes "$pane" "$dir" "$host"
	done
	# In the clobbered shape Mash's own directories can only lead if MASH_BIN
	# names them; the bundle's directories are merely somewhere in the inherited
	# PATH, so nothing here can put them first. That shape is what mash-shell
	# must never produce, and it is checked below.
	assert_precedes "$clobbered" "$home/.mash/bin" "$host"
done

# PATH is rebuilt as three tiers, so an element appears exactly once even when
# MASH_BIN and the inherited PATH name it too. The old form appended MASH_BIN to
# a prefix it was also still present in, which left /opt/homebrew/bin (or
# ~/.mash/bin) twice; the clobbered shape is where that shows.
assert_no_duplicate_elements() {
	local out="$1" path dup
	path="$(printf '%s\n' "$out" | sed -n 's/^PATH=//p')"
	dup="$(printf '%s' "$path" | tr ':' '\n' | sort | uniq -d)"
	if [ -n "$dup" ]; then
		printf 'duplicate PATH elements: %s\n' "$dup" >&2
		printf '%s' "$path" | tr ':' '\n' | sed 's/^/  /' >&2
		exit 1
	fi
}
assert_no_duplicate_elements "$clobbered"
assert_no_duplicate_elements "$pane"

# Every program Mash ships must resolve inside the bundle on the session PATH
# of a pane pointed at the installed app. This is the check that would have
# caught the regression above without a person reading `ps eww`: a host twin
# silently winning is invisible everywhere else.
app="${MASH_APP:-/Applications/Mash.app}"
res="$app/Contents/Resources"

resolve_with_path() {
	local path="$1" name="$2" dir
	while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		[ -x "$dir/$name" ] && [ ! -d "$dir/$name" ] || continue
		printf '%s\n' "$dir/$name"
		return 0
	done < <(printf '%s\n' "$path" | tr ':' '\n')
	return 1
}

if [ -d "$res/node/bin" ]; then
	bundle_path="$(
		env -i HOME="$home" PATH="/usr/bin:/bin" \
			MASH_BIN="$res/bin:$res/node/bin:$res/python/bin:$home/.mash/bin" \
			bash -c 'source "$1"; mash_isolate "$2" pane; printf "%s\n" "$PATH"' \
			_ "$lib" "$home"
	)"
	shipped=0
	for dir in "$res/bin" "$res/node/bin" "$res/python/bin"; do
		for exe in "$dir"/*; do
			[ -x "$exe" ] || continue
			name="$(basename "$exe")"
			# lib.sh is Mash's shared shell library, not a program.
			[ "$name" = "lib.sh" ] && continue
			shipped=$((shipped + 1))
			resolved="$(resolve_with_path "$bundle_path" "$name" || true)"
			case "$resolved" in
			"$res"/*) ;;
			*)
				printf 'FAIL %s resolves to %s, outside %s\n' \
					"$name" "${resolved:-<not found>}" "$res" >&2
				exit 1
				;;
			esac
			done
	done
	[ "$shipped" -gt 0 ] || {
		printf 'no shipped programs found under %s\n' "$res" >&2
		exit 1
	}
	echo "shipped programs checked: $shipped"
else
	echo "no app bundle at $app; skipped the shipped-program audit"
fi

# mash_isolate must not reach outside the HOME it is given. The bun directory
# is $HOME/.bun/bin, so a run under the test's scratch HOME must never pull in
# the real one: the owner's installed programs would leak into a pane and the
# test would pass for the wrong reason.
case "$(printf '%s\n' "$pane" | sed -n 's/^PATH=//p')" in
*"$HOME/.bun/bin"*)
	printf 'mash_isolate leaked the real ~/.bun/bin into a scratch HOME run\n' >&2
	exit 1
	;;
esac

# mash-bin resolves through MASH_BIN, not PATH, and falls back when Mash's
# directories do not hold the name.
mkdir -p "$tmp/fixture/node/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/fixture/node/bin/pi"
chmod 755 "$tmp/fixture/node/bin/pi"
mash_bin="$(cd "$(dirname "$0")/.." && pwd)/helpers/mash-bin"
got="$(MASH_BIN="$tmp/fixture/node/bin" "$mash_bin" pi)"
[ "$got" = "$tmp/fixture/node/bin/pi" ] || {
	printf 'mash-bin ignored MASH_BIN: got %s\n' "$got" >&2
	exit 1
}
got="$(MASH_BIN="$tmp/fixture/bin" "$mash_bin" sh)"
[ "$got" = "/bin/sh" ] || {
	printf 'mash-bin did not fall back to PATH: got %s\n' "$got" >&2
	exit 1
}

# A shipped program must not be reachable by bare name through PATH when the
# bundle is not on it at all: that is the state a launcher has to survive, and
# why the launchers resolve pi and python3 with mash-bin.
not_ours="$(MASH_BIN="$tmp/fixture/bin" "$mash_bin" pi)"
case "$not_ours" in
"$tmp/fixture"/*)
	printf 'mash-bin reported a bundle path for a program the bundle lacks\n' >&2
	exit 1
	;;
esac

# mash-shell must keep the MASH_BIN herdr-pane built. Rebuilding it from its
# own directory alone is the clobbered shape above: the bundled pi, node and
# python3 then stay on PATH only because the inherited PATH still holds them,
# and the pane runs Homebrew's copies the moment it does not.
shell_root="$(cd "$(dirname "$0")/.." && pwd)"
stub_dir="$tmp/stub"
mkdir -p "$stub_dir"
for name in stub-shell bash; do
	cat >"$stub_dir/$name" <<'EOF'
#!/bin/sh
printf 'MASH_BIN=%s\n' "$MASH_BIN"
printf 'PATH=%s\n' "$PATH"
printf 'ARGS=%s\n' "$*"
EOF
	chmod 755 "$stub_dir/$name"
done

run_pane_shell() {
	env -i HOME="$home" PATH="/usr/bin:/bin" \
		MASH_BIN="$tmp/app/bin:$tmp/app/node/bin:$home/.mash/bin" \
		MASH_USER_SHELL="$1" \
		bash "$shell_root/mash-shell"
}

pane_shell="$(run_pane_shell "$stub_dir/stub-shell")"
for dir in "$tmp/app/bin" "$tmp/app/node/bin"; do
	case "$(printf '%s\n' "$pane_shell" | sed -n 's/^MASH_BIN=//p')" in
	*"$dir"*) ;;
	*)
		printf 'mash-shell dropped %s from MASH_BIN:\n%s\n' "$dir" "$pane_shell" >&2
		exit 1
		;;
	esac
done
for host in /opt/homebrew/bin /usr/local/bin; do
	[ -d "$host" ] || continue
	for dir in "$tmp/app/bin" "$tmp/app/node/bin"; do
		assert_precedes "$pane_shell" "$dir" "$host"
	done
done

# bash has no ZDOTDIR, so it is the one shell whose own startup could reorder
# PATH after isolation; it must be started with --norc. zsh is covered by
# ZDOTDIR pointing at Mash's config directory instead.
bash_shell="$(run_pane_shell "$stub_dir/bash")"
assert_value "$bash_shell" ARGS --norc

# A shipped program must not be reachable by bare name through PATH when the
# bundle is not on it at all: that is the state a launcher has to survive, and
# why the launchers resolve pi and python3 with mash-bin.
not_ours="$(MASH_BIN="$tmp/fixture/bin" "$mash_bin" pi)"
case "$not_ours" in
"$tmp/fixture"/*)
	printf 'mash-bin reported a bundle path for a program the bundle lacks\n' >&2
	exit 1
	;;
esac

# A real directory that is on PATH must actually resolve, which is what the
# mangled form silently broke for every Homebrew tool.
for tool in fd rg eza fzf bat; do
	[ -x "/opt/homebrew/bin/$tool" ] || continue
	printf '%s' "$(printf '%s\n' "$pane" | sed -n 's/^PATH=//p')" | tr ':' '\n' |
		grep -qxF -- /opt/homebrew/bin || {
		printf '%s is installed but its directory is not a PATH element\n' "$tool" >&2
		exit 1
	}
done

# --- instances -------------------------------------------------------------
# A second Mash window gets its own workspaces and tabs by getting its own
# Herdr session, while every setting stays shared. Herdr keeps a session's
# layout in its session directory, so a distinct session is what makes the
# workspaces distinct; the socket alone would leave both servers writing one
# session.json.

# The default instance must be byte-for-byte what it was before instances
# existed: same socket, no session name. Anything else silently re-homes every
# existing user's workspaces.
assert_value "$pane" MASH_INSTANCE default
assert_unset "$pane" HERDR_SESSION
assert_unset "$launch" HERDR_SESSION
assert_value "$launch" HERDR_CLIENT_SOCKET_PATH "$home/.mash/run/herdr-client.sock"

second="$(run_isolate pane default 2)"
assert_value "$second" MASH_INSTANCE 2
assert_value "$second" HERDR_SESSION 2
assert_value "$second" HERDR_SOCKET_PATH "$home/.mash/run/2/herdr.sock"
assert_value "$second" HERDR_CLIENT_SOCKET_PATH "$home/.mash/run/2/herdr-client.sock"

# Shared settings are the point of this mode: the config, the agent directory
# and the editor state must be identical across instances. Only the socket and
# the session may differ.
for key in HERDR_CONFIG_PATH XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME \
	PI_CODING_AGENT_DIR PI_HOME MASH_FRESH_CONFIG_DIR MASH_FRESH_DATA_DIR; do
	want="$(printf '%s\n' "$pane" | sed -n "s/^${key}=//p")"
	assert_value "$second" "$key" "$want"
done

# A name that could escape ~/.mash/run or that Herdr would reject falls back to
# the default instead of failing a launch the user cannot otherwise recover.
for bad in "../escape" "a/b" ""; do
	out="$(run_isolate pane default "$bad")"
	assert_value "$out" MASH_INSTANCE default
	assert_value "$out" HERDR_SOCKET_PATH "$home/.mash/run/herdr.sock"
done

# The allocator behind an icon click: the first window takes the restored
# instance, a window opened while it is live gets a fresh one, and an instance
# whose window died is reused rather than stranded.
claim() {
	env -i HOME="$home" PATH="/usr/bin:/bin" \
		bash -c 'source "$1"; mash_claim_instance "$2" "$3"' _ "$lib" "$home" "$1"
}
mark() {
	env -i HOME="$home" PATH="/usr/bin:/bin" \
		bash -c 'source "$1"; mash_mark_instance_window "$2" "$3" "$4"' \
		_ "$lib" "$home" "$1" "$2"
}
release() {
	env -i HOME="$home" PATH="/usr/bin:/bin" \
		bash -c 'source "$1"; mash_release_instance_window "$2" "$3" "$4"' \
		_ "$lib" "$home" "$1" "$2"
}

got="$(claim 4242)"
[ "$got" = default ] || {
	printf 'first claim must take the default instance, got %s\n' "$got" >&2
	exit 1
}
# $$ is alive, so this marker means "this instance has a live window".
mark default "$$"
got="$(claim 4243)"
[ "$got" = 2 ] || {
	printf 'a claim beside a live default must get instance 2, got %s\n' "$got" >&2
	exit 1
}
mark 2 "$$"
got="$(claim 4244)"
[ "$got" = 3 ] || {
	printf 'a third claim must get instance 3, got %s\n' "$got" >&2
	exit 1
}

# A window that exits frees its instance for the next click.
release 2 "$$"
got="$(claim 4245)"
[ "$got" = 2 ] || {
	printf 'a released instance must be reused, got %s\n' "$got" >&2
	exit 1
}

# A marker naming a pid that no longer exists is stale -- a crash or a reboot --
# and must not strand the instance forever.
mark 2 999999
got="$(claim 4246)"
[ "$got" = 2 ] || {
	printf 'a stale marker must free its instance, got %s\n' "$got" >&2
	exit 1
}

# Releasing is owner-only: a relaunch may already hold the instance, and
# dropping its marker would hand the same instance to the next click while that
# window is still open -- the clone bug, reintroduced.
mark 2 "$$"
release 2 999999
[ -f "$home/.mash/run/2/window.pid" ] || {
	printf 'a non-owner release removed the marker\n' >&2
	exit 1
}

# Two clicks at once must never land on one instance. The claim is a mkdir,
# which is atomic everywhere; a check-then-write would hand both the same name.
race="$tmp/race"
rm -rf "$home/.mash/run" "$race"
mkdir -p "$home/.mash/run"
for _ in 1 2 3 4 5 6; do
	(
		env -i HOME="$home" PATH="/usr/bin:/bin" bash -c '
			source "$1"
			inst="$(mash_claim_instance "$2" "$$")"
			mash_mark_instance_window "$2" "$inst" "$$"
			printf "%s\n" "$inst"
			sleep 3
		' _ "$lib" "$home" >>"$race"
	) &
done
wait 2>/dev/null || true
total="$(wc -l <"$race" | tr -d ' ')"
distinct="$(sort -u "$race" | wc -l | tr -d ' ')"
[ "$total" = "$distinct" ] || {
	printf 'concurrent claims collided: %s claims, %s distinct\n' "$total" "$distinct" >&2
	sort "$race" | sed 's/^/  /' >&2
	exit 1
}

echo "mash_isolate: ok"