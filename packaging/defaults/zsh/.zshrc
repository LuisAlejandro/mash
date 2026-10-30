# Mash pane startup, zsh interactive side.
#
# ZDOTDIR points at this directory, so this is the only zsh config read:
# ~/.zshrc is never touched. /etc/zshrc still runs first and zsh has no flag to
# skip it, which is why bash reads its system rc too (see config/bash/bashrc).
#
# The other two jobs -- MASH_BIN to the front of PATH, and atuin's hook -- live
# in .zshenv beside this file, because a pane also runs non-interactive zsh
# scripts and those need the path too.
#
# The PATH work is repeated here on purpose. zsh reads $ZDOTDIR/.zshenv BEFORE
# /etc/zshrc (verified: HISTSIZE is still zsh's built-in 30 when .zshenv runs,
# and /etc/zshrc sets 2000), so a system file that prepended a directory would
# land ahead of a prepend made only in .zshenv. Doing it again here makes this
# file the last word on PATH for every interactive zsh pane, which is what bash
# (--rcfile runs after /etc/bash.bashrc) and fish ($XDG_CONFIG_HOME/fish/
# config.fish runs after /etc/fish/config.fish) already get. `typeset -U path`
# keeps the repeat idempotent: the directories are already present, so they are
# moved, not duplicated.
if [[ -n ${MASH_BIN:-} ]]; then
  typeset -U path
  path=(${(s/:/)MASH_BIN} $path)
fi

# Native completion. Keep the dump in Mash's cache, never ZDOTDIR or ~/.zcompdump.
autoload -Uz compinit
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
compinit -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-$ZSH_VERSION"

# Autosuggestions are shipped read-only in the app bundle.
for _mash_bin_dir in ${(s/:/)MASH_BIN}; do
  _mash_autosuggest="${_mash_bin_dir:h}/share/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"
  if [[ -r $_mash_autosuggest ]]; then
    source "$_mash_autosuggest"
    break
  fi
done
unset _mash_bin_dir _mash_autosuggest

# Starship owns the shared prompt. The plain prompt remains a startup fallback.
PROMPT='%F{green}%~%f ❯ '
if (( $+commands[starship] )); then
  eval "$(starship init zsh)"
fi

# A pane Herdr restored as a shell while its agent was running reopens that
# agent: macOS kills pi at logout before Herdr saves, so Herdr's own record of
# the agent is lost. mash-pane-resume runs once per pane and returns when there
# is nothing to reopen. See packaging/helpers/mash-pane-resume.
if [[ -n ${HERDR_PANE_ID:-} && -o interactive ]] && (( $+commands[mash-pane-resume] )); then
  mash-pane-resume
fi
