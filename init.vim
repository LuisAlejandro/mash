"   This file is part of Mash
"   Copyright (c) 2016, Mash Developers
"
"   Please refer to CONTRIBUTORS.md for a complete list of Copyright
"   holders.
"
"   Mash is free software: you can redistribute it and/or modify
"   it under the terms of the GNU General Public License as published by
"   the Free Software Foundation, either version 3 of the License, or
"   (at your option) any later version.
"
"   Mash is distributed in the hope that it will be useful,
"   but WITHOUT ANY WARRANTY; without even the implied warranty of
"   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
"   GNU General Public License for more details.
"
"   You should have received a copy of the GNU General Public License
"   along with this program. If not, see <http://www.gnu.org/licenses/>.

set nocompatible

let $VIM='~/.config/mash/runtime'
let $VIMRUNTIME='~/.config/mash/runtime'
set runtimepath=$VIMRUNTIME,~/.config/mash/plug

call plug#begin('~/.config/mash/plugins')

Plug 'CollageLabs/mash', {'dir': '~/.config/mash/app', 'do': './configure.sh', 'branch': 'develop'}
Plug 'CollageLabs/vim-autoswap', {'branch': 'master'}
Plug 'xolox/vim-misc', {'commit': '3e6b8fb6f03f13434543ce1f5d24f6a5d3f34f0b'}
Plug 'xolox/vim-easytags', {'commit': '72a8753b5d0a951e547c51b13633f680a95b5483'}
Plug 'tomtom/tcomment_vim', {'tag': '3.08'}
Plug 'kristijanhusak/vim-multiple-cursors', {'commit': 'a95edcdffd98c5961f067796fbc2a1a82e0f6a83'}
Plug 'junegunn/goyo.vim', {'commit': '5b8bd0378758c1d9550d8429bef24b3d6d78b592'}
Plug 'jiangmiao/auto-pairs', {'tag': 'v1.3.3'}
Plug 'dkprice/vim-easygrep', {'commit': 'd0c36a77cc63c22648e792796b1815b44164653a'}
Plug 'vim-syntastic/syntastic', {'tag': '3.8.0'}
Plug 'sheerun/vim-polyglot', {'tag': 'v2.17.0'}
Plug 'Shougo/vimproc.vim', {'do': 'make', 'tag': 'ver.9.2'}
Plug 'Shougo/unite.vim', {'commit': 'ada33d888934d8a9e60aa8ff828b651aaedb6457'}
Plug 'Shougo/neocomplete.vim', {'commit': '4fd73faa262f5e3063422d9fc244c65f1b758cf3'}
Plug 'Shougo/neosnippet.vim', {'commit': '9996520d6bf1aaee21f66b5eb561c9f0b306216c'}
Plug 'Shougo/neosnippet-snippets', {'commit': '2a9487bacb924d8e870612b6b0a2afb34deea0ae'}
Plug 'preservim/nerdtree', {'tag': '5.0.0'}
Plug 'vim-airline/vim-airline', {'tag': 'v0.8'}
Plug 'tpope/vim-fugitive', {'tag': 'v2.2'}
Plug 'airblade/vim-gitgutter', {'commit': 'b803a28f47b26d16f5fe9e747850992c9985c667'}
Plug 'ryanoasis/vim-devicons', {'tag': 'v0.9.2'}

call plug#end()
