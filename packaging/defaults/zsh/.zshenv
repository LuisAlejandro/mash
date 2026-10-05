# Mash pane startup. ZDOTDIR points here, so the user's shell startup is not read.
if [[ -n ${MASH_BIN:-} ]]; then
  typeset -U path
  path=(${(s/:/)MASH_BIN} $path)
fi
if (( $+commands[atuin] )); then
  eval "$(atuin init zsh)"
fi
