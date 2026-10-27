# Mash pane startup, fish side.
#
# XDG_CONFIG_HOME points at Mash's config tree, so this is the only fish config
# read: ~/.config/fish/config.fish is never touched. On Linux
# /etc/fish/config.fish still runs first, the same way /etc/zshrc runs for zsh;
# fish has no flag that skips it.
#
# Four jobs, matching config/zsh/.zshenv/.zshrc and config/bash/bashrc:
#   1. MASH_BIN to the front of PATH
#   2. native completion (fish provides it)
#   3. atuin's shell hook
#   4. the Starship prompt
# tests/test_pane_shell_rc.sh fails when the three drift apart.

# MASH_BIN holds the bundle's program directories, in order (herdr-pane built
# it, mash-shell augmented it). fish_add_path prepends, dedupes and is
# idempotent in one call -- the fish spelling of zsh's `typeset -U path`.
if set -q MASH_BIN
    for dir in (string split : -- $MASH_BIN)
        fish_add_path --global --prepend --move $dir
    end
end

if type -q atuin
    atuin init fish | source
end

# Starship owns the shared prompt. The plain prompt remains a startup fallback.
function fish_prompt
    set_color green
    string replace -r "^$HOME" '~' $PWD
    set_color normal
    printf ' ❯ '
end
if type -q starship
    starship init fish | source
end
