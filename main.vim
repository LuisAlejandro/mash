set nocompatible
set runtimepath=~/.subliminal-vim,$VIMRUNTIME

runtime bundle/vim-pathogen/autoload/pathogen.vim
execute pathogen#infect()

runtime common.vim
runtime keymap.vim
runtime library.vim
runtime commands.vim
runtime plugins.vim
