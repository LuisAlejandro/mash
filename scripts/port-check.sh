#!/bin/bash
# port-check.sh -- retire this Mac's personal agent setup without losing
# anything Mash did not absorb.
#
# The rule: an item is only retired when its Mash counterpart is found on
# disk. Everything else is reported and left alone, whether it is unported
# work, personal data, host tooling, or a source repo.
#
# Run this from inside the installed Mash (its panes keep $HOME at the real
# home, so the personal paths below are the ones it sees).
#
#   scripts/port-check.sh                       # read-only report (default)
#   scripts/port-check.sh --groups              # list staging groups
#   scripts/port-check.sh --group shell --apply # quarantine one group
#   scripts/port-check.sh --apply               # quarantine every group
#   scripts/port-check.sh --apply --include-shared  # also the shared ones
#   scripts/port-check.sh --quarantine DIR      # choose where things go
#   scripts/port-check.sh --selftest            # check the checker
#
# Quarantine moves, it does not delete. Live with Mash for a while, then
# remove the quarantine folder yourself.
set -uo pipefail

MASH_APP="${MASH_APP:-/Applications/Mash.app}"
QUARANTINE=""
GROUP_FILTER=""
APPLY=0
INCLUDE_SHARED=0
SELFTEST=0
LIST_GROUPS=0

RES=""
DEFAULTS=""
DATA=""
PLAN=""
GROUP=""

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

# Citing the plan file keeps the report and the apply pass on one set of
# findings, so a path cannot be reported as verified and then skipped.
plan() { printf '%s\t%s\t%s\t%s\n' "$GROUP" "$1" "$2" "$3" >>"$PLAN"; }

# Retire `src` only if Mash carries it. ev1/ev2 are evidence paths; either one
# existing is enough. Order matters: evidence is checked at report time.
consider() {
    local src="$1" ev1="$2" ev2="$3" label="$4"
    [ -e "$src" ] || return 0
    if [ -e "$ev1" ] || { [ -n "$ev2" ] && [ -e "$ev2" ]; }; then
        plan PORTED "$src" "$label"
    else
        plan UNVERIFIED "$src" "$label"
    fi
}

# A shared item is verified present in Mash, but the personal copy is also
# read by the user's own terminal. Reported, and held back from --apply
# unless --include-shared is passed.
consider_shared() {
    local src="$1" ev1="$2" ev2="$3" label="$4"
    [ -e "$src" ] || return 0
    if [ -e "$ev1" ] || { [ -n "$ev2" ] && [ -e "$ev2" ]; }; then
        plan SHARED "$src" "$label"
    else
        plan UNVERIFIED "$src" "$label"
    fi
}

# Shared directories are walked per entry instead of wholesale, which is what
# protects the skills and agents Mash does not ship.
consider_each() {
    local dir="$1" ev_dir="$2" ev_dir2="$3" label="$4"
    [ -d "$dir" ] || return 0
    local entry name
    for entry in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        case "$name" in .DS_Store|__pycache__|.skill-lock.json) continue ;; esac
        if [ -e "$ev_dir/$name" ] || { [ -n "$ev_dir2" ] && [ -e "$ev_dir2/$name" ]; }; then
            plan PORTED "$entry" "$label"
        else
            plan UNPORTED "$entry" "$label not in Mash"
        fi
    done
}

keep() { printf '%s\t%s\t%s\t%s\n' "$GROUP" "$2" "$1" "$3" >>"$PLAN"; }

survey() {
    local h="$HOME"
    local bin="$RES/bin" plugins="$RES/plugins" pidef="$DEFAULTS/pi" name font
    local cfg="$DATA/config" ghostty_fonts="$RES/Ghostty.app/Contents/Resources/Fonts"

    # --- 1 launch chain ---------------------------------------------------
    GROUP="1-launch"
    consider "$h/Applications/Herdr.app" "$MASH_APP" "" "replaced by Mash.app"

    # --- 2 background watchers -------------------------------------------
    # Mash ships and runs its own. Quarantining these unloads the LaunchAgent.
    GROUP="2-watchers"
    consider "$h/Library/LaunchAgents/com.luisalejandro.git-status-watch.plist" \
        "$bin/git-status-watch" "" "watcher now inside Mash"
    consider "$h/Library/LaunchAgents/com.luisalejandro.pr-watch-repo.plist" \
        "$bin/pr-watch-repo" "" "watcher now inside Mash"

    # --- 3 helper scripts from ~/dotfiles/bin ----------------------------
    GROUP="3-helpers"
    for name in herdr-agent-name herdr-dev-tab-fill herdr-fresh-pane \
        herdr-new-dev-tab herdr-new-pi-tab herdr-new-plain-tab \
        herdr-new-reviewr-tab herdr-shell-greeting telescope-files \
        git-status-watch pr-watch-repo; do
        consider "$h/dotfiles/bin/$name" "$bin/$name" "" "bundled helper"
    done

    # --- 4 herdr plugins from ~/dotfiles/plugins/herdr -------------------
    GROUP="4-plugins"
    for name in cache-hit dev-tab fingers fork-from-message herdr-workspace \
        pr-watch-focus telescope; do
        consider "$h/dotfiles/plugins/herdr/$name" "$plugins/$name" "" "bundled plugin"
    done

    # --- 5 fonts ----------------------------------------------------------
    GROUP="5-fonts"
    for font in "MesloLGS NF Regular.ttf" "MesloLGS NF Bold.ttf" \
        "MesloLGS NF Italic.ttf" "MesloLGS NF Bold Italic.ttf"; do
        consider "$h/Library/Fonts/$font" "$ghostty_fonts/$font" "" "font inside Mash Ghostty"
    done

    # --- 6 seeded configs -------------------------------------------------
    GROUP="6-config"
    consider "$h/.config/herdr" "$cfg/herdr" "$DEFAULTS/herdr" "herdr config seeded"
    consider_shared "$h/.config/ghostty" "$cfg/ghostty" "$DEFAULTS/ghostty" "seeded, but your own Ghostty reads it"
    consider "$h/.config/fresh" "$cfg/fresh" "$DEFAULTS/fresh" "fresh config seeded"
    consider_shared "$h/.config/pet" "$cfg/pet" "$DEFAULTS/pet" "seeded, but your own pet reads it"
    consider_shared "$h/.config/lazydocker" "$cfg/lazydocker" "$DEFAULTS/lazydocker" "seeded, but your own lazydocker reads it"
    consider_shared "$h/.config/atuin" "$cfg/atuin" "$DEFAULTS/atuin" "seeded, but your own shell reads it"

    # --- 7 pi components, per entry --------------------------------------
    GROUP="7-pi"
    consider "$h/.pi/agent/settings.json" "$DATA/pi/agent/settings.json" \
        "$pidef/settings.json" "pi settings seeded"
    consider_each "$h/.pi/agent/extensions" "$pidef/extensions" \
        "$DATA/pi/agent/extensions" "pi extension"
    consider_each "$h/.pi/agent/skills" "$pidef/skills" \
        "$DATA/pi/agent/skills" "skill"
    consider_each "$h/.agents" "$pidef/agents" "$DATA/pi/agent/agents" "agent"

    # --- 8 shell ----------------------------------------------------------
    GROUP="8-shell"
    consider_shared "$h/.atuin" "$bin/atuin" "" "bundled, but ~/.zshrc sources this one"

    # --- pi personal data: reported so the reader knows it is deliberate --
    GROUP="keep"
    for name in sessions missions auth.json trust.json models.json \
        models-store.json run-history.jsonl web-search.json npm bin scripts; do
        [ -e "$h/.pi/agent/$name" ] && keep "$h/.pi/agent/$name" KEEP "your data, not a component"
    done
    keep "$h/.pi/agent" KEEP "shared: only the entries listed above are touched"
    keep "$h/.local/share/atuin" KEEP "your shell history"
    keep "$h/.local/state/atuin" KEEP "your shell history state"
    keep "$h/dotfiles" KEEP "bin/ and plugins/herdr are handled per entry above; keybinding maps, actions-reference, LSP docs, gen scripts and images stay here permanently"
    keep "$h/.cursor" KEEP "Cursor IDE and its config"
    keep "$h/Development/rosey" KEEP "unrelated projects"
    keep "$h/Development/second-brain" KEEP "unrelated projects"
    keep "/Applications/Ghostty.app" KEEP "your own terminal, not a Mash source"

    # --- not ported: separate stacks Mash does not carry ------------------
    keep "$h/.config/opencode" UNPORTED "OpenCode: installed Mash ships no opencode"
    keep "$h/.opencode" UNPORTED "OpenCode data"
    if [ -d "$DEFAULTS/pi/skills/mash-design-setup" ]; then
        consider "$h/.config/mash" "$DATA/config/mash" "" "MSP and design install; Mash seeds its own"
        consider_shared "$h/.local/bin/mds" "$DATA/bin/mds" "" "design stack CLI"
    else
        keep "$h/.config/mash" UNPORTED "MSP install plus a design stack Mash does not carry yet"
        keep "$h/.local/bin/mds" UNPORTED "design stack CLI"
    fi
    # The wizard installs this and the bundled mcp.json names it, so the panes
    # need it. Never a quarantine candidate.
    keep "$h/.local/bin/cua-driver" HOST "Mash's wizard installs it; mcp.json calls it"
    keep "$h/.local/bin/agent" KEEP "Cursor CLI wrapper, not a Mash component"
    keep "$h/.config/mcp" UNPORTED "pi-mcp-adapter file, not shipped"
    # Mash carries Hindsight now, but your own daemon still owns these paths:
    # they are held behind --include-shared for that reason. The evidence is the
    # config Mash ships, so these resolve as soon as Mash is reinstalled rather
    # than waiting for the first-launch download.
    hint="$DEFAULTS/mash-config/hindsight-embed.env"
    consider_shared "$h/.local/bin/hindsight" "$hint" "" "the client CLI; Mash installs its own"
    consider_shared "$h/.local/bin/hindsight-embed" "$hint" "" "the embed shim; Mash installs its own"
    consider_shared "$h/.local/share/uv/tools/hindsight-embed" "$hint" "" "the 1.8 GB env; your own daemon is running from it"
    keep "$h/.hindsight" KEEP "your existing memory bank and logs; Mash's is separate"
    keep "$h/.pg0" KEEP "embedded Postgres data behind your own Hindsight"

    # --- host tooling Mash borrows: deleting this breaks Mash -------------
    keep "/opt/homebrew" HOST "git gh fzf fd bat rg jq delta eza zoxide sentrux uv gpg + language servers"
    keep "$h/.bun" HOST "bun and bunx live here, not in Homebrew; lib.sh puts ~/.bun/bin on every pane PATH"
    keep "$h/.gitconfig" HOST "your git identity; Mash uses its own git config"
    keep "$h/.gitignore-global" HOST "global excludes"
    keep "/Applications/Xcode.app" HOST "system git and make"
    keep "/Applications/Docker.app" HOST "docker daemon"

    # --- source repos needed to rebuild Mash ------------------------------
    keep "$h/Development/mash-programming-skills" KEEP "upstream: build.sh requires this checkout"
    keep "$h/Development/maintainer-tools" KEEP "upstream: release and CI templates"
    keep "$h/Development/mash-design-skills" KEEP "upstream: design stack"
}

selected() {
    [ -z "$GROUP_FILTER" ] && return 0
    [ "$1" = "$GROUP_FILTER" ]
}

report() {
    local group status count
    printf 'PLAN\n'
    for group in $(
        awk -F'\t' '{print $1}' "$PLAN" | awk '!seen[$0]++'
    ); do
        selected "$group" || continue
        printf '\n-- group %s\n' "$group"
        awk -F'\t' -v g="$group" '$1==g {printf "   %-8s %-58s %s\n", $2, $3, $4}' "$PLAN"
    done
    printf '\nSUMMARY\n'
    for status in PORTED SHARED UNVERIFIED UNPORTED KEEP HOST; do
        count="$(awk -F'\t' -v s="$status" '$2==s' "$PLAN" | wc -l | tr -d ' ')"
        [ "$count" = 0 ] && continue
        case "$status" in
        PORTED)     printf '   %-11s %2s  safe to quarantine\n' "$status" "$count" ;;
        SHARED)     printf '   %-11s %2s  verified in Mash, but your own shell reads it\n' "$status" "$count" ;;
        UNVERIFIED) printf '   %-11s %2s  MISSING from Mash -- left alone\n' "$status" "$count" ;;
        UNPORTED)   printf '   %-11s %2s  Mash does not carry these -- left alone\n' "$status" "$count" ;;
        KEEP)       printf '   %-11s %2s  personal or upstream -- left alone\n' "$status" "$count" ;;
        HOST)       printf '   %-11s %2s  Mash needs these -- left alone\n' "$status" "$count" ;;
        esac
    done
}

apply() {
    local group status src label rel dest moved=0
    mkdir -p "$QUARANTINE"
    while IFS=$'\t' read -r group status src label; do
        case "$status" in
        PORTED) ;;
        SHARED) [ "$INCLUDE_SHARED" = 1 ] || continue ;;
        *) continue ;;
        esac
        selected "$group" || continue
        case "$src" in
        */Library/LaunchAgents/*.plist)
            # A loaded job whose program just moved retries and logs errors
            # every interval, so unload it before the file goes.
            label="$(basename "$src" .plist)"
            if launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; then
                printf '   unloaded %s\n' "$label"
            fi
            ;;
        esac
        rel="${src#"$HOME"/}"
        dest="$QUARANTINE/$rel"
        mkdir -p "$(dirname "$dest")"
        if mv "$src" "$dest"; then
            printf '   quarantined %s\n' "$rel"
            moved=$((moved + 1))
        else
            printf '   FAILED to move %s\n' "$src" >&2
        fi
    done <"$PLAN"
    printf '\nMoved %s item(s) to %s\n' "$moved" "$QUARANTINE"
    printf 'Nothing was deleted. Remove that folder once Mash has proven itself.\n'
}

selftest() {
    local tmp rc=0
    tmp="$(mktemp -d)"
    HOME="$tmp"
    PLAN="$tmp/plan"
    : >"$PLAN"
    GROUP="t"
    mkdir -p "$tmp/personal/keepme" "$tmp/personal/dropme" "$tmp/mash/dropme"
    : >"$tmp/personal/keepme/f"
    : >"$tmp/personal/dropme/f"
    : >"$tmp/mash/dropme/f"

    consider_each "$tmp/personal" "$tmp/mash" "" "t"
    grep -q "UNPORTED.*keepme" "$PLAN" || { echo "FAIL: unported item was not protected"; rc=1; }
    grep -q "PORTED.*dropme" "$PLAN" || { echo "FAIL: ported item not recognised"; rc=1; }

    QUARANTINE="$tmp/q"
    apply >/dev/null
    [ -d "$tmp/personal/keepme" ] || { echo "FAIL: unported item was moved"; rc=1; }
    [ -e "$tmp/personal/dropme" ] && { echo "FAIL: ported item was not moved"; rc=1; }
    [ -d "$tmp/q/personal/dropme" ] || { echo "FAIL: quarantine copy missing"; rc=1; }

    # Both groups must survive into the plan, and a group filter must select
    # only its own entries.
    : >"$PLAN"
    mkdir -p "$tmp/g/a" "$tmp/g/b"
    : >"$tmp/g/a/f"
    : >"$tmp/g/b/f"
    GROUP="a"; consider "$tmp/g/a/f" "$tmp/mash/dropme" "" "t"
    GROUP="b"; consider "$tmp/g/b/f" "$tmp/mash/dropme" "" "t"
    [ "$(awk -F'\t' '$1=="a"' "$PLAN" | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: plan lost group a"; rc=1; }
    [ "$(awk -F'\t' '$1=="b"' "$PLAN" | wc -l | tr -d ' ')" = 1 ] || { echo "FAIL: plan lost group b"; rc=1; }
    GROUP_FILTER="a"
    QUARANTINE="$tmp/q2"
    apply >/dev/null
    [ -e "$tmp/g/a/f" ] && { echo "FAIL: group a was not quarantined"; rc=1; }
    [ -e "$tmp/g/b/f" ] || { echo "FAIL: group filter leaked into group b"; rc=1; }
    GROUP_FILTER=""

    rm -rf "$tmp"
    [ "$rc" = 0 ] && echo "selftest: ok"
    return "$rc"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
        --apply) APPLY=1 ;;
        --include-shared) INCLUDE_SHARED=1 ;;
        --quarantine) shift; QUARANTINE="${1:?--quarantine needs a directory}" ;;
        --group) shift; GROUP_FILTER="${1:?--group needs a name}" ;;
        --groups) LIST_GROUPS=1 ;;
        --selftest) SELFTEST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
        esac
        shift
    done

    if [ "$SELFTEST" = 1 ]; then
        selftest
        exit $?
    fi

    # Retiring the tree that is currently serving this shell would kill it.
    # Mash points its own socket and agent dir into ~/.mash, so either
    # signature means the personal setup is live in this process.
    local personal_live=0
    case "${HERDR_SOCKET_PATH:-}" in
    "$HOME/.config/herdr"*) personal_live=1 ;;
    esac
    if [ "$personal_live" = 1 ]; then
        if [ "$APPLY" = 1 ]; then
            echo "Refusing: this shell belongs to the personal Herdr setup." >&2
            echo "Open /Applications/Mash.app and run this from a Mash pane." >&2
            exit 1
        fi
        echo "Note: this shell is the personal setup, so --apply is disabled here." >&2
        echo "      Read-only report follows. Run --apply from a Mash pane." >&2
    fi

    [ -d "$MASH_APP" ] || { echo "Mash is not installed at $MASH_APP" >&2; exit 1; }
    RES="$MASH_APP/Contents/Resources"
    DEFAULTS="$RES/defaults"
    DATA="$HOME/.mash"
    PLAN="$(mktemp -t port-check.XXXXXX)"
    trap 'rm -f "$PLAN"' EXIT

    survey

    if [ "$LIST_GROUPS" = 1 ]; then
        awk -F'\t' '$2=="PORTED" || $2=="SHARED" {print $1}' "$PLAN" | sort -u |
            while read -r g; do
                printf '%-12s %s item(s)\n' "$g" \
                    "$(awk -F'\t' -v g="$g" '($1==g) && ($2=="PORTED" || $2=="SHARED")' "$PLAN" | wc -l | tr -d ' ')"
            done
        exit 0
    fi

    report

    if [ "$APPLY" = 1 ]; then
        if [ -z "$QUARANTINE" ]; then
            QUARANTINE="$HOME/Mash-retired-$(date +%Y%m%d-%H%M%S)"
        fi
        printf '\n== APPLY%s: quarantining verified items\n' \
            "${GROUP_FILTER:+ group $GROUP_FILTER}"
        apply
    else
        printf '\nRead-only. Re-run with --apply to quarantine the %s verified item(s).\n' \
            "$(awk -F'\t' '$2=="PORTED"' "$PLAN" | wc -l | tr -d ' ')"
    fi
}

main "$@"
