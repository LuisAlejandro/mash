" Sublime Text key noremappings




" Text editing
noremap <silent> <C-a> gg<S-v>G

" Move a line of text using ALT+[jk] or Comamnd+[jk] on mac
nnoremap <silent> <C-S-Down> mz:m+<cr>`z
vnoremap <silent> <C-S-Down> :m'>+<cr>`<my`>mzgv`yo`z
nnoremap <silent> <C-S-Up> mz:m-2<cr>`z
vnoremap <silent> <C-S-Up> :m'<-2<cr>`>my`<mzgv`yo`z

" duplicate the selection
nnoremap <silent> <Esc>[68;5~ yyp
vnoremap <silent> <Esc>[68;5~ yp
inoremap <silent> <Esc>[68;5~ <Esc>yypi

" indent / deindent after selecting the text with (⇧ v), (.) to repeat.
vnoremap <silent> <Tab> >gv
nnoremap <silent> <Tab> >>
vnoremap <silent> <S-Tab> <gv
nnoremap <silent> <S-Tab> <<

" Cut, Paste, Copy
vnoremap <silent> <C-x> "xygvd:call system('xsel -i -b', @x)<CR>v
nnoremap <silent> <C-x> "xdd:call system('xsel -i -b', @x)<CR>
inoremap <silent> <C-x> <Esc>"xdd:call system('xsel -i -b', @x)<CR>i

vnoremap <silent> <C-v> :let @x=system('xsel -b')<CR>"xpv
nnoremap <silent> <C-v> :let @x=system('xsel -b')<CR>"xp
inoremap <silent> <C-v> <Esc>:let @x=system('xsel -b')<CR>"xpi

vnoremap <silent> <C-c> "xy:call system('xsel -i -b', @x)<CR>v
nnoremap <silent> <C-c> "xyy:call system('xsel -i -b', @x)<CR>
inoremap <silent> <C-c> <Esc>"xyy:call system('xsel -i -b', @x)<CR>i

" Undo, Redo
nnoremap <silent> <C-z> :undo<CR>
inoremap <silent> <C-z> <Esc>:undo<CR>
vnoremap <silent> <C-z> <Esc>:undo<CR>
nnoremap <silent> <C-y> :redo<CR>
inoremap <silent> <C-y> <Esc>:redo<CR>
vnoremap <silent> <C-y> <Esc>:redo<CR>


" Buffers (tabs) ----------------------------------------------------

" Save tab
nnoremap <silent> <C-s> :w<CR>
inoremap <silent> <C-s> <Esc>:w<CR>
vnoremap <silent> <C-s> <Esc>:w<CR>

" Save all tabs
nnoremap <silent> <C-e> :wa<CR>
inoremap <silent> <C-e> <Esc>:wa<CR>
vnoremap <silent> <C-e> <Esc>:wa<CR>

" Close tab
nnoremap <silent> <C-w> :bp <BAR> bd #<CR>
inoremap <silent> <C-w> <Esc>:bp <BAR> bd #<CR>
vnoremap <silent> <C-w> <Esc>:bp <BAR> bd #<CR>

" Close all tabs
nnoremap <silent> <C-q> :bufdo bd<CR>
inoremap <silent> <C-q> <Esc>:bufdo bd<CR>
vnoremap <silent> <C-q> <Esc>:bufdo bd<CR>

" Move back and forth through previous and next tabs
" with ,z and ,x
noremap <silent> <leader>z :bprevious<CR>
noremap <silent> <leader>x :bnext<CR>

" To open a new empty tab
nnoremap <silent> <leader>n :e<SPACE>

" Windows (splits) --------------------------------------------------

" Create window splits easier
nnoremap <silent> <leader>v <C-w>v
nnoremap <silent> <leader>s <C-w>s

" Close split
nnoremap <silent> <leader>q <C-w>q

" Navigate between split buffers windows
nnoremap <silent> <C-Down> <C-w>j<C-w>_
nnoremap <silent> <C-Up> <C-w>k<C-w>_
nnoremap <silent> <C-Left> <C-w>h<C-w>_
nnoremap <silent> <C-Right> <C-w>l<C-w>_

" Resize windows with arrow keys
" nnoremap <silent> <S-Up> <C-w>+
" nnoremap <silent> <S-Down> <C-w>-
" nnoremap <silent> <S-Left> <C-w><
" nnoremap <silent> <S-Right>  <C-w>>
"
" Console (quickfix) ------------------------------------------------
" ,q to toggle quickfix window (where you have stuff like Ag)
" ,oq to open it back up (rare)
nnoremap <silent> <leader>qc :cclose<CR>
nnoremap <silent> <leader>qo :copen<CR>


" Navigation =================================================================

" Make 0 go to the first character rather than the beginning
" of the line. When we're programming, we're almost always
" interested in working with text rather than empty space. If
" you want the traditional beginning of line, use ^
nnoremap 0 ^
nnoremap ^ 0


"     vnoremap <C-c> "+ygv<Esc>
"     vnoremap <C-x> "+d<Esc>
"
"     noremap <C-v>  "+gP
"     cnoremap <C-v> <C-r>+
"
"     exe 'inoremap <script> <C-v>' paste#paste_cmd['i']
"     exe 'vnoremap <script> <C-v>' paste#paste_cmd['v']
"
"   " For CTRL-v to work autoselect must be off.
"   " On Unix we have two selections, autoselect can be used.
"   if !has('unix')
"     set guioptions-=a
"   endif
"
"   " ,q and ,e - toggle quickfix window and location list
"   nnoremap <silent> ,q :call <SID>ToggleList('Quickfix List', 'c')<CR>
"   nnoremap <silent> ,e :call <SID>ToggleList('Location List', 'l')<CR>
"   function! GetBufferList() " {{{
"     redir =>buflist
"     silent! ls
"     redir END
"     return buflist
"   endfunction " }}}
"   function! s:ToggleList(bufname, pfx) " {{{
"     let buflist = GetBufferList()
"     for bufnum in noremap(filter(split(buflist, '\n'), 'v:val =~ "'.a:bufname.'"'), 'str2nr(matchstr(v:val, "\\d\\+"))')
"       if bufwinnr(bufnum) != -1
"         exec(a:pfx.'close')
"         if a:pfx == 'l'
"           execute 'SyntasticReset'
"         endif
"         return
"       endif
"     endfor
"
"     if a:pfx == 'c' && !len(getqflist())
"       echohl Question
"       echo "Quickfix list is empty."
"       return
"     elseif a:pfx == 'l' && !len(getloclist(0))
"       echohl Question
"       echo "Location list is empty."
"       return
"     endif
"
"     let winnr = winnr()
"     exec(a:pfx.'open')
"     if winnr() != winnr
"       wincmd p
"     endif
"   endfunction " }}}
"
"   " resize quickfix windows to their content, or 20 lines maximum
"   autocmd vimrc FileType qf call <SID>ResizeWindow(2, 20)
"   function! s:ResizeWindow(min, max) " {{{
"     let max = min([a:max, &lines / 3])
"     execute max([a:min, min([max, line('$') + 1])]).'wincmd _'
"   endfunction " }}}
"
"   " Ctrl-c - remove highlighted search and redraw
"   nnoremap <silent> <C-c> :nohlsearch<CR>:call UncolorAllWords()<CR>:redraw!<CR>
"
"   " <count>` - switch buffers
"   nnoremap <silent><expr> ` v:count ? ":<C-u>b<C-r>=v:count<CR><CR>" : "`"
"
"   " <count>~ - delete buffers
"   nnoremap <silent><expr> ~ v:count ? ":<C-u>bd<C-r>=v:count<CR><CR>" : "~"
"
"   " ,n / ,p - next/previous buffer
"   nnoremap <silent> ,n :call SwitchBuffer(1)<CR>
"   nnoremap <silent> ,p :call SwitchBuffer(-1)<CR>
"   function! SwitchBuffer(delta)
"     let buffers = []
"     for nr in range(1, bufnr('$'))
"       if buflisted(nr) && getbufvar(nr, 'current_syntax') != 'qf'
"         call add(buffers, nr)
"       end
"     endfor
"
"     if len(buffers) == 0
"       return
"     endif
"
"     let position = index(buffers, bufnr('%')) + a:delta
"
"     if position < 0
"       let position = len(buffers) - 1
"     elseif position > len(buffers) - 1
"       let position = 0
"     endif
"
"     execute 'buffer' . buffers[position]
"   endfunction
"
"   " ,c - close current window, unless it's the only one
"   nnoremap <silent> ,c :call <SID>CloseWindow()<CR>
"   function! s:CloseWindow() " {{{
"     " get number of visible buffers
"     let buffers = len(filter(range(1, bufnr('$')), 'buflisted(v:val)'))
"
"     if winnr('$') > 1
"       if bufname('%') == '[Command Line]'
"         close
"       else
"         lclose
"         wincmd c
"       endif
"     endif
"   endfunction " }}}
"
"   " ,x - close the current buffer, keeping windows
"   nnoremap <silent> ,x :silent lclose<CR>:silent Bdelete<CR>
"
"   " ,X - close the current buffer, not keeping windows
"   nnoremap <silent> ,X :silent lclose<CR>:silent bd<CR>
"
"   " ,d - open definition in new window
"   nnoremap <silent> ,d <C-w>f
"
"   " ,r - reload current buffer
"   nnoremap <silent> ,r :edit<CR>
"
"   " ,R - reload vimrc
"   nnoremap <silent> ,R :runtime! vimrc gvimrc<CR>:nohlsearch<CR>
"
"   " ,s - split horizontally
"   nnoremap <silent> ,s :split<CR>
"
"   " ,v - split vertically
"   nnoremap <silent> ,v :vsplit<CR>
"
"   " ,w - write current buffer
"   nnoremap <silent> ,w :write<CR>:redraw<CR>
"
"   " ,W - write all open buffers
"   nnoremap <silent> ,W :wall<CR>:redraw<CR>
"
"   " ,$ - clear trailing whitespace
"   nnoremap <silent> ,$ :call <SID>ClearTrailingWhitespace()<CR>
"   function! s:ClearTrailingWhitespace() " {{{
"     Preserve 'silent %s/\s\s*$//e'
"     echohl Question
"     echo "Trailing whitespace cleared"
"     echohl none
"   endfunction " }}}
"
"   " ,F - toggle fold method
"   nnoremap <silent> ,F :call ToggleFoldMethod()<CR>
"   function! ToggleFoldMethod() " {{{
"     if &foldcolumn == 0
"       echohl Question
"       echomsg "Folding..."
"       echohl none
"       if &filetype == 'python'
"         setlocal foldmethod=indent
"       else
"         setlocal foldmethod=syntax
"       endif
"       setlocal foldcolumn=3
"     else
"       setlocal foldcolumn=0 foldmethod=marker
"     endif
"   endfunction " }}}
"
"   " ,g and ,G - grep the current file or path
"   nnoremap <silent> ,g :call <SID>GrepWrapper('%')<CR>
"   nnoremap <silent> ,G :call <SID>GrepWrapper('.')<CR>
"   function! s:GrepWrapper(path) " {{{
"     if a:path == '%' && empty(expand('%'))
"       echo "Can't grep unsaved file."
"       return
"     endif
"
"     echohl Question
"     let pattern = substitute(input("Grep " . (a:path == '%' ? 'buffer' : 'recursive') . ": /", expand('<cword>')), '"', '\"', '')
"
"     if !empty(pattern)
"       echohl Question
"       echo "/ searching..."
"       execute 'silent! grep ' . shellescape(pattern) . ' ' . a:path . ' /dev/null'
"       redraw!
"
    "       let matches = len(getqflist())
"       if matches > 0
"         echo matches . " " . (matches == 1 ? "match" : "matches") . " found"
"       else
"         echohl WarningMsg
"         echo "Pattern not found: " . pattern
"       endif
"     endif
"
"     echohl None
"   endfunction " }}}
"
"   " ,N - toggle line numbers
"   nnoremap <silent> ,N :call <SID>ToggleLineNumbers()<CR>
"   function! s:ToggleLineNumbers() " {{{
"     if &number
"       set nonumber norelativenumber
"     else
"       set number norelativenumber
"     endif
"   endfunction " }}}
""     " The default leader is '\', but many people prefer ',' as it's in a standard
"     " location. To override this behavior and set it back to '\' (or any other
"     " character) add the following to your .vimrc.before.local file:
"     "   let g:spf13_leader='\'
"     if !exists('g:spf13_leader')
"         let noremapleader = ','
"     else
"         let noremapleader=g:spf13_leader
"     endif
"     if !exists('g:spf13_localleader')
"         let noremaplocalleader = '_'
"     else
"         let noremaplocalleader=g:spf13_localleader
"     endif
"
"     " The default noremappings for editing and applying the spf13 configuration
"     " are <leader>ev and <leader>sv respectively. Change them to your preference
"     " by adding the following to your .vimrc.before.local file:
"     "   let g:spf13_edit_config_noremapping='<leader>ec'
"     "   let g:spf13_apply_config_noremapping='<leader>sc'
"     if !exists('g:spf13_edit_config_noremapping')
"         let s:spf13_edit_config_noremapping = '<leader>ev'
"     else
"         let s:spf13_edit_config_noremapping = g:spf13_edit_config_noremapping
"     endif
"     if !exists('g:spf13_apply_config_noremapping')
"         let s:spf13_apply_config_noremapping = '<leader>sv'
"     else
"         let s:spf13_apply_config_noremapping = g:spf13_apply_config_noremapping
"     endif
"
"     " Easier moving in tabs and windows
"     " The lines conflict with the default digraph noremapping of <C-K>
"     " If you prefer that functionality, add the following to your
"     " .vimrc.before.local file:

"     " Wrapped lines goes down/up to next row, rather than next line in file.
"     noremap j gj
"     noremap k gk
"
"     " End/Start of line motion keys act relative to row/wrap width in the
"     " presence of `:set wrap`, and relative to line for `:set nowrap`.
"     " Default vim behaviour is to act relative to text line in both cases
"     " If you prefer the default behaviour, add the following to your
"     " .vimrc.before.local file:
"     "   let g:spf13_no_wrapRelMotion = 1
"     if !exists('g:spf13_no_wrapRelMotion')
"         " Same for 0, home, end, etc
"         function! WrapRelativeMotion(key, ...)
"             let vis_sel=""
"             if a:0
"                 let vis_sel="gv"
"             endif
"             if &wrap
"                 execute "normal!" vis_sel . "g" . a:key
"             else
"                 execute "normal!" vis_sel . a:key
"             endif
"         endfunction
"
"         " noremap g* keys in Normal, Operator-pending, and Visual+select
"         noremap $ :call WrapRelativeMotion("$")<CR>
"         noremap <End> :call WrapRelativeMotion("$")<CR>
"         noremap 0 :call WrapRelativeMotion("0")<CR>
"         noremap <Home> :call WrapRelativeMotion("0")<CR>
"         noremap ^ :call WrapRelativeMotion("^")<CR>
"         " Overwrite the operator pending $/<End> noremappings from above
"         " to force inclusive motion with :execute normal!
"         onoremap $ v:call WrapRelativeMotion("$")<CR>
"         onoremap <End> v:call WrapRelativeMotion("$")<CR>
"         " Overwrite the Visual+select mode noremappings from above
"         " to ensure the correct vis_sel flag is passed to function
"         vnoremap $ :<C-U>call WrapRelativeMotion("$", 1)<CR>
"         vnoremap <End> :<C-U>call WrapRelativeMotion("$", 1)<CR>
"         vnoremap 0 :<C-U>call WrapRelativeMotion("0", 1)<CR>
"         vnoremap <Home> :<C-U>call WrapRelativeMotion("0", 1)<CR>
"         vnoremap ^ :<C-U>call WrapRelativeMotion("^", 1)<CR>
"     endif
"
"     " The following two lines conflict with moving to top and
"     " bottom of the screen
"     " If you prefer that functionality, add the following to your
"     " .vimrc.before.local file:
"     "   let g:spf13_no_fastTabs = 1
"     if !exists('g:spf13_no_fastTabs')
"         noremap <S-H> gT
"         noremap <S-L> gt
"     endif
"
"     " Stupid shift key fixes
"     if !exists('g:spf13_no_keyfixes')
"         if has("user_commands")
"             command! -bang -nargs=* -complete=file E e<bang> <args>
"             command! -bang -nargs=* -complete=file W w<bang> <args>
"             command! -bang -nargs=* -complete=file Wq wq<bang> <args>
"             command! -bang -nargs=* -complete=file WQ wq<bang> <args>
"             command! -bang Wa wa<bang>
"             command! -bang WA wa<bang>
"             command! -bang Q q<bang>
"             command! -bang QA qa<bang>
"             command! -bang Qa qa<bang>
"         endif
"
"         cnoremap Tabe tabe
"     endif
"
"     " Yank from the cursor to the end of the line, to be consistent with C and D.
"     nnoremap Y y$
"
"     " Code folding options
"     nnoremap <leader>f0 :set foldlevel=0<CR>
"     nnoremap <leader>f1 :set foldlevel=1<CR>
"     nnoremap <leader>f2 :set foldlevel=2<CR>
"     nnoremap <leader>f3 :set foldlevel=3<CR>
"     nnoremap <leader>f4 :set foldlevel=4<CR>
"     nnoremap <leader>f5 :set foldlevel=5<CR>
"     nnoremap <leader>f6 :set foldlevel=6<CR>
"     nnoremap <leader>f7 :set foldlevel=7<CR>
"     nnoremap <leader>f8 :set foldlevel=8<CR>
"     nnoremap <leader>f9 :set foldlevel=9<CR>
"
"     " Most prefer to toggle search highlighting rather than clear the current
"     " search results. To clear search highlighting rather than toggle it on
"     " and off, add the following to your .vimrc.before.local file:
"     "   let g:spf13_clear_search_highlight = 1
"     if exists('g:spf13_clear_search_highlight')
"         nnoremap <silent> <leader>/ :nohlsearch<CR>
"     else
"         nnoremap <silent> <leader>/ :set invhlsearch<CR>
"     endif
"
"
"     " Find merge conflict markers
"     noremap <leader>fc /\v^[<\|=>]{7}( .*\|$)<CR>
"
"     " Shortcuts
"     " Change Working Directory to that of the current file
"     cnoremap cwd lcd %:p:h
"     cnoremap cd. lcd %:p:h
"
"     " Visual shifting (does not exit Visual mode)
"     vnoremap < <gv
"     vnoremap > >gv
"
"     " Allow using the repeat operator with a visual selection (!)
"     " http://stackoverflow.com/a/8064607/127816
"     vnoremap . :normal .<CR>
"
"     " For when you forget to sudo.. Really Write the file.
"     cnoremap w!! w !sudo tee % >/dev/null
"
"     " Some helpers to edit mode
"     " http://vimcasts.org/e/14
"     cnoremap %% <C-R>=fnameescape(expand('%:h')).'/'<cr>
"     noremap <leader>ew :e %%
"     noremap <leader>es :sp %%
"     noremap <leader>ev :vsp %%
"     noremap <leader>et :tabe %%
"
"     " Adjust viewports to the same size
"     noremap <Leader>= <C-w>=
"
"     " noremap <Leader>ff to display all lines with keyword under cursor
"     " and ask which one to jump to
"     nnoremap <Leader>ff [I:let nr = input("Which one: ")<Bar>exe "normal " . nr ."[\t"<CR>
"
"     " Easier horizontal scrolling
"     noremap zl zL
"     noremap zh zH
"
"     " Easier formatting
"     nnoremap <silent> <leader>q gwip
"
"     " FIXME: Revert this f70be548
"     " fullscreen mode for GVIM and Terminal, need 'wmctrl' in you PATH
"     noremap <silent> <F11> :call system("wmctrl -ir " . v:windowid . " -b toggle,fullscreen")<CR>
"
" " }

