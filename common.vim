filetype plugin on
filetype indent on

" Indentation

set nowrap
set autoindent
set smartindent
set smarttab
set shiftwidth=4
set softtabstop=4
set tabstop=4
set expandtab

" Folds

set foldnestmax=3                               " deepest fold is 3 levels
set foldmethod=indent                           " fold based on indent
set nofoldenable                                " dont fold by default

" Completion

set wildmenu                                    "enable ctrl-n and ctrl-p to scroll thru matches
set wildmode=list:longest,full
set wildignore=*.pyc,*.o,*.lo,*.la,*.exe,*.swp,*.db,*.bak,*.old,*.dat,*.,tmp,*.mdb,*~,~*
"
" Scrolling

set scrolloff=8                                 " Start scrolling when we're 8 lines away from margins
set sidescrolloff=15
set sidescroll=1

" UI

set lazyredraw
set number                                      " show line numbers
set showcmd                                     " show command in bottom bar
set showmode                                    " Show current mode down the bottom
set cursorline                                  " highlight current line
set showmatch                                   " highlight matching [{()}]
set incsearch                                   " search as characters are entered
set hlsearch                                    " highlight matches
set ignorecase                                  " Ignore case when searching...
set smartcase                                   " ...unless we type a capital
set textwidth=80
set colorcolumn=-1
set list
set listchars=tab:--,trail:·,extends:#,nbsp:.
set backspace=indent,eol,start                     " Allow backspace in insert mode
set history=1000                                " Store lots of :cmdline history
set novisualbell                                  " No sounds
set laststatus=2

set hidden                                        " This makes vim act like all other editors, buffers can
                                                " exist in the background without being in a window.
                                                " http://items.sjbach.com/319/configuring-vim-right
syntax on                                           " turn on syntax highlighting
set splitright                  " Split vertical windows right to the current windows
set splitbelow                  " Split horizontal windows below to the current windows

let mapleader=','                                " Change leader to a comma because the backslash is too far away
                                                " That means all \x commands turn into ,x
                                                " The mapleader has to be set before vundle starts loading all
                                                " the plugins.

set mouse=a
set mousehide
set guioptions-=m  "remove menu bar
set guioptions-=T  "remove toolbar
set guioptions-=r  "remove right-hand scroll bar
set guioptions-=L  "remove left-hand scroll bar
set guifont=Droid\ Sans\ Mono\ for\ Powerline\ 11

set encoding=utf-8              " Set default encoding to UTF-8
scriptencoding utf-8

" Swap files

set autoread                                    " Reload files changed outside vim
set autowrite                                    " Automatically save before :next, :make etc.
set noswapfile
set nobackup
set nowritebackup

" Color themes

colorscheme monokai                     " color scheme
set t_Co=256                            " tell the term has 256 colors



set pastetoggle=<F2>


" Use one space, not two, after punctuation.
set nojoinspaces


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" => Turn persistent undo on
"    means that you can undo even when you close a buffer/VIM
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
set undodir=~/.vim/tempdir
set undofile
set undolevels=1000         " Maximum number of changes that can be undone
set undoreload=10000        " Maximum number lines to save for undo on a buffer reload

" window/icon titles
set title
set icon
let &titlestring = '%t%m%r\ \[%{ProjectFilepath(1)}\]'
let &iconstring = &titlestring

set clipboard=unnamed,unnamedplus
set shortmess+=filmnrxoOtT          " Abbrev. of messages (avoids 'hit enter')
set viewoptions=folds,options,cursor,unix,slash " Better Unix / Windows compatibility
set virtualedit=onemore             " Allow for cursor beyond last character
set iskeyword-=.                    " '.' is an end of word designator
set iskeyword-=#                    " '#' is an end of word designator
set iskeyword-=-                    " '-' is an end of word designator

set linespace=0                 " No extra spaces between rows
set whichwrap=b,s,h,l,<,>,[,]   " Backspace and cursor keys wrap too
set listchars=tab:--,trail:•,extends:#,nbsp:. " Highlight problematic whitespace


" Fix Alt mappings
" http://stackoverflow.com/a/10216459
"
" let c='a'
" while c <= 'z'
"   exec "set <A-".c.">=\e".c
"   exec "imap \e".c." <A-".c.">"
"   let c = nr2char(1+char2nr(c))
" endw
"
set timeout ttimeoutlen=50

" " Tab completion
" " will insert tab at beginning of line,
" " will use completion if not at beginning
" set wildmode=list:longest,list:full
" function! InsertTabWrapper()
"     let col = col('.') - 1
"     if !col || getline('.')[col - 1] !~ '\k'
"         return "\<tab>"
"     else
"         return "\<c-p>"
"     endif
" endfunction
" inoremap <Tab> <c-r>=InsertTabWrapper()<cr>
" inoremap <S-Tab> <c-n>

