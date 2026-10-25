# Mash pane startup. ZDOTDIR points here, so the user's shell startup is not read.
# Fresh ships with a WARN default that still honors RUST_LOG, so panes do not
# set it here: overriding it would clobber a value the user chose on purpose.
if [[ -n ${MASH_BIN:-} ]]; then
  typeset -U path
  path=(${(s/:/)MASH_BIN} $path)
fi
if (( $+commands[atuin] )); then
  eval "$(atuin init zsh)"
fi
