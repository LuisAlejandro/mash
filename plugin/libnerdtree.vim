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


function! NERDTreePatch()
    let l:curlinen = line('.')
    let l:spacetoken = "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n"
    let l:finaltoken = spacetoken . spacetoken

    if &ft ==# 'nerdtree'
        setlocal nolist
        setlocal modifiable
        silent $put = l:finaltoken
        setlocal nomodifiable
        silent execute "normal ".l:curlinen."G"
        let &colorcolumn = join(range(1,300),",")
        highlight ColorColumn ctermbg=254 guibg=#e4e4e4
        highlight CursorLine ctermfg=0 cterm=bold guifg=#000000 gui=bold
    else
        highlight CursorLine ctermfg=NONE cterm=NONE guifg=NONE gui=NONE
    endif
endfunction

function! NERDTreeInit()
    if PlugIsInstalled('nerdtree') &&  PlugIsInstalled('vim-devicons')
        NERDTreeToggle
        call webdevicons#hardRefresh()
        call NERDTreePatch()
        wincmd w
        highlight CursorLine ctermfg=NONE cterm=NONE guifg=NONE gui=NONE
    endif
endfunction

function! NERDTreeRefresh()
    if PlugIsInstalled('nerdtree')
        call NERDTreeFocus()
        " let l:curlinen = line('.')
        call g:NERDTree.ForCurrentTab().getRoot().refresh()
        call g:NERDTree.ForCurrentTab().render()
        call NERDTreePatch()
        " silent execute "normal ".l:curlinen."G"
        wincmd w
        highlight CursorLine ctermfg=NONE cterm=NONE guifg=NONE gui=NONE
    endif
endfunction

augroup nerdtree_init_patch_refresh
    autocmd!
    autocmd VimEnter * call NERDTreeInit()
    autocmd CursorMoved,WinEnter,BufWinEnter,BufEnter,WinLeave,BufWinLeave,BufLeave * call NERDTreePatch()
    autocmd CursorHold,CursorHoldI * call NERDTreeRefresh()
augroup END