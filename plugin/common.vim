"   This file is part of Subliminal View
"   Copyright (c) 2016, Subliminal View Developers
"
"   Please refer to CONTRIBUTORS.md for a complete list of Copyright
"   holders.
"
"   Subliminal View is free software: you can redistribute it and/or modify
"   it under the terms of the GNU General Public License as published by
"   the Free Software Foundation, either version 3 of the License, or
"   (at your option) any later version.
"
"   Subliminal View is distributed in the hope that it will be useful,
"   but WITHOUT ANY WARRANTY; without even the implied warranty of
"   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
"   GNU General Public License for more details.
"
"   You should have received a copy of the GNU General Public License
"   along with this program. If not, see <http://www.gnu.org/licenses/>.


" Compatibility

syntax on                                       " Turn on syntax highlighting
filetype plugin on
filetype indent on

" UI

set insertmode                                  " Get rid of normal mode
set hidden                                      " Tabs can exist in the
                                                " backgound without having to
                                                " open them everytime
set lazyredraw                                  " Defer redraw (faster)
set noshowcmd                                   " Dont show command in cmd bar
set noshowmode                                  " Dont show edit mode in cmd bar
set nomore                                      " Hide the --more-- tag
set wildmenu                                    " Enable completion in cmd bar
set wildmode=list:longest                       " Mode for completion in cmd bar
set number                                      " Show line numbers
set cursorline                                  " Highlight current line
set showmatch                                   " Highlight matching [{()}]
set backspace=2                                 " Behaviour of backspace
set laststatus=2                                " Always show a status line
set splitright                                  " Split vertical windows right to the current windows
set splitbelow                                  " Split horizontal windows below to the current windows
set list listchars=tab:--,trail:·,nbsp:·        " Formatting of spaces in text

" Color theme

set termguicolors								" User GUI colors on terminal
colorscheme subliminal                          " color scheme

" Window/icon titles

set title
set icon
let &titlestring='%F (%{ProjectFilePath(1)}) - Subliminal View'
let &iconstring=&titlestring

" Mouse

set mouse=a                                     " Activate mouse in all modes
set mousemodel=popup                            " Use right click to initiate popup
                                                " doesn't work in console mode
                                                " but that's just what we want
set virtualedit=onemore                         " Allow for cursor beyond last character
let &t_SI = "\<Esc>[5 q"                        " Blinking cursor (insert)
let &t_SR = "\<Esc>[4 q"                        " Underline cursor (replace)
let &t_EI = "\<Esc>[2 q"                        " Blinking cursor (normal)

" Keyboard

set timeout ttimeoutlen=50                      " Lower keyboard timeout for
                                                " faster key shortcuts

" Indentation

set nowrap                                      " Avoid wrapping long lines
set autoindent                                  " Help with indenting
set smartindent                                 " Help with indenting
set smarttab                                    " Better tabs (actually spaces)
set expandtab                                   " Better tabs (actually spaces)
set shiftwidth=4                                " Better tabs (actually spaces)
set softtabstop=4                               " Better tabs (actually spaces)
set tabstop=4                                   " Better tabs (actually spaces)

" Search

set incsearch                                   " search as characters are entered
set hlsearch                                    " highlight matches
set ignorecase                                  " Ignore case when searching...
set smartcase                                   " ...unless we type a capital

" Files

set encoding=utf-8                              " Set default encoding to UTF-8
set autoread                                    " Reload files changed outside vim
set autowriteall                                " Automatically save before :next, :make etc.

" Viminfo file

set viminfo^=%
set viminfo+=n~/.config/subliminal-view/viminfo

" Ctags file

set tags=~/.config/subliminal-view/vimtags

" Swap files dir

set swapfile
set updatecount=1
set directory=~/.config/subliminal-view/recovery/

" Backups dir

set backup
set writebackup
set backupdir=~/.config/subliminal-view/backups/

" Undo history dir

set history=1000
set undofile
set undodir=~/.config/subliminal-view/undo/
