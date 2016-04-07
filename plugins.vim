" ----------------------------------------------------------------------------
" SEARCH FUNCTIONS
" ----------------------------------------------------------------------------

" bundle/incsearch.vim
" ------------------------------------------------------------------
" <C-f>         - Search-forward entire file with visual increment (incsearch)
" <C-b>         - Search-backward entire file with visual increment (incsearch)
" <C-g>         - Search (still cursor) entire file with visual increment (incsearch)

let g:incsearch#consistent_n_direction = 1
let g:incsearch#emacs_like_keymap = 1
let g:incsearch#auto_nohlsearch = 1

map <silent> <C-f> <Plug>(incsearch-forward)
map <silent> /     <Plug>(incsearch-forward)
map <silent> <C-b> <Plug>(incsearch-backward)
map <silent> ?     <Plug>(incsearch-backward)
map <silent> <C-g> <Plug>(incsearch-stay)
map <silent> g/    <Plug>(incsearch-stay)

nmap <silent> n <Plug>(incsearch-nohl-n)
nmap <silent> N <Plug>(incsearch-nohl-N)
nmap <silent> * <Plug>(incsearch-nohl-*)
nmap <silent> # <Plug>(incsearch-nohl-#)
nmap <silent> g* <Plug>(incsearch-nohl-g*)
nmap <silent> g# <Plug>(incsearch-nohl-g#)


" bundle/ag.vim
" ------------------------------------------------------------------

" Ag should search only on project root
let g:ag_working_path_mode='r'

" Use Ag over Grep
set grepprg=ag\ --vimgrep

" Call Ag to search for term in project
nmap <silent> <leader>pf :call SearchProject()<CR>

" Search for selected term in file (forwards)
vmap <silent> <leader>ff :call VSearchFile('f')<CR>

" Search for selected term in file (backwards)
vmap <silent> <leader>fb :call VSearchFile('b')<CR>

" Replace selected term with another inside file
vmap <silent> <leader>fr :call VSearchReplaceFile()<CR>



" bundle/vim-easygrep
" ------------------------------------------------------------------
" <leader>vv    - Grep for the word under the cursor, match all occurences, like 'g*'
" <leader>vV    - Grep for the word under the cursor, match whole word, like '*'.
" <leader>va    - Like vv, but add to existing list.
" <leader>vA    - Like vV, but add to existing list.
" <leader>vr    - Perform a global search on the word under the cursor and prompt for a pattern with which to replace it.
" <leader>vR    - Like vr, but match whole word.

let g:EasyGrepCommand = 1


" bundle/ctrlp.vim
" ------------------------------------------------------------------

let g:ctrlp_map = '<C-p>'
let g:ctrlp_cmd = 'CtrlP'            " search anything (in files, buffers and MRU files at the same time.)

" Use ag in CtrlP for listing files. Lightning fast and respects .gitignore
let g:ctrlp_user_command = 'ag -Q -l --nocolor --hidden -g "" %s'

let g:ctrlp_use_caching = 0 " ag is fast enough that CtrlP doesn't need to cache
let g:ctrlp_working_path_mode = 'ra'    " search for nearest ancestor like .git, .hg, and the directory of the current file
let g:ctrlp_switch_buffer = 'et'        " jump to a file if it's open already
let g:ctrlp_clear_cache_on_exit = 0          " speed up by not removing clearing cache evertime
let g:ctrlp_mruf_max = 250                 " number of recently opened files

let g:ctrlp_extensions = ['tag', 'buffertag']
let g:ctrlp_buftag_types = {
    \ 'go'         : '--language-force=go --golang-types=ftv',
    \ 'coffee'     : '--language-force=coffee --coffee-types=cmfvf',
    \ 'markdown'   : '--language-force=markdown --markdown-types=hik',
    \ 'objc'       : '--language-force=objc --objc-types=mpci',
    \ 'rc'         : '--language-force=rust --rust-types=fTm'
    \ }


" bundle/auto-pairs
" ------------------------------------------------------------------



" bundle/conflict-marker.vim
" ------------------------------------------------------------------
" co - Accept ourselves
" ct - Accept themselves
" cn - Accept none
" cb - Accept both


" bundle/emmet-vim
" ------------------------------------------------------------------
let g:user_emmet_leader_key='<C-m>'
let g:user_emmet_install_global = 0

autocmd FileType html,css EmmetInstall


" bundle/gitv
" ------------------------------------------------------------------
let g:Gitv_OpenHorizontal = 1
nmap <silent> <leader>gv :Gitv! --all<CR>


" bundle/goyo.vim
" ------------------------------------------------------------------
nmap <silent> <leader>zz :Goyo<CR>:NERDTreeTabsToggle<CR>


" bundle/indentLine
" ------------------------------------------------------------------
let g:indentLine_color_term = 239


" bundle/nerdtree
" ------------------------------------------------------------------

" Make nerdtree look nice
let NERDTreeMinimalUI = 1
let NERDTreeIgnore=['\.py[cd]$', '\~$', '\.swo$', '\.swp$', '^\.git$', '^\.hg$', '^\.svn$', '\.bzr$']
let NERDTreeShowHidden=1

" Toggle NERDTree
nmap <silent> <leader>nt :NERDTreeTabsToggle<CR>


" bundle/vim-nerdtree-tabs
" ------------------------------------------------------------------
" Always open at startup
let g:nerdtree_tabs_open_on_console_startup=1
let g:nerdtree_tabs_open_on_gui_startup=1

" Focus in the main content window
let g:nerdtree_tabs_focus_on_files = 1


" bundle/syntastic
" ------------------------------------------------------------------

" mark syntax errors with :signs
let g:syntastic_enable_signs = 1

" automatically jump to the error when saving the file
let g:syntastic_auto_jump = 0

" show the error list automatically
let g:syntastic_auto_loc_list = 1

let g:syntastic_always_populate_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0


set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

nmap <silent> <leader>st :SyntasticToggleMode<CR>
nmap <silent> <leader>sc :SyntasticCheck<CR>

" Python
let g:syntastic_python_checkers = ['python', 'pep8', 'pylint', 'pyflakes', 'pydocstyle']
let g:syntastic_python_python_exec = '~/.subliminal-vim/sandboxes/python/bin/python'
let g:syntastic_python_pep8_exec = '~/.subliminal-vim/sandboxes/python/bin/pep8'
let g:syntastic_python_pylint_exec = '~/.subliminal-vim/sandboxes/python/bin/pylint'
let g:syntastic_python_pyflakes_exec = '~/.subliminal-vim/sandboxes/python/bin/pyflakes'
let g:syntastic_python_pydocstyle_exec = '~/.subliminal-vim/sandboxes/python/bin/pydocstyle'

" Ruby
let g:syntastic_ruby_checkers = ['mri', 'rubocop']
let g:syntastic_ruby_mri_exec = '~/.subliminal-vim/sandboxes/ruby/ruby/2.3.0/bin/ruby'
let g:syntastic_ruby_rubocop_exec = '~/.subliminal-vim/sandboxes/ruby/ruby/2.3.0/bin/rubocop'

" Shell
let g:syntastic_sh_checkers = ['sh', 'shellcheck', 'checkbashisms']

" Javascript
let g:syntastic_javascript_checkers = ['jshint', 'jscs']
let g:syntastic_javascript_jshint_exec =  '~/.subliminal-vim/sandboxes/node/node_modules/.bin/jshint'
let g:syntastic_javascript_jscs_exec =  '~/.subliminal-vim/sandboxes/node/node_modules/.bin/jscs'

" Go
let g:syntastic_go_checkers = ['go', 'gometalinter']

" Markdown
let g:syntastic_markdown_checkers = ['textlint']
let g:syntastic_markdown_textlint_exec =  '~/.subliminal-vim/sandboxes/node/node_modules/.bin/textlint'

" HTML
let g:syntastic_html_checkers = ['textlint']
let g:syntastic_html_textlint_exec =  '~/.subliminal-vim/sandboxes/node/node_modules/.bin/textlint'

" CSS
let g:syntastic_css_checkers = ['csslint']
let g:syntastic_css_csslint_exec =  '~/.subliminal-vim/sandboxes/node/node_modules/.bin/csslint'

" C
let g:syntastic_c_checkers = ['clang_tidy']

" C++
let g:syntastic_cpp_checkers = ['clang_tidy']

" Vim
let g:syntastic_vim_checkers = ['vint']
let g:syntastic_vim_vint_exec = '~/.subliminal-vim/sandboxes/python/bin/vint'

" SQL
let g:syntastic_sql_checkers = ['sqlint']
let g:syntastic_sql_sqlint_exec = '~/.subliminal-vim/sandboxes/ruby/ruby/2.3.0/bin/sqlint'

" PHP
let g:syntastic_php_checkers = ['php']


" bundle/tabular
" ------------------------------------------------------------------
nmap <silent> <leader>a& :Tabularize /&<CR>
vmap <silent> <leader>a& :Tabularize /&<CR>
nmap <silent> <leader>a= :Tabularize /^[^=]*\zs=<CR>
vmap <silent> <leader>a= :Tabularize /^[^=]*\zs=<CR>
nmap <silent> <leader>a=> :Tabularize /=><CR>
vmap <silent> <leader>a=> :Tabularize /=><CR>
nmap <silent> <leader>a: :Tabularize /:<CR>
vmap <silent> <leader>a: :Tabularize /:<CR>
nmap <silent> <leader>a:: :Tabularize /:\zs<CR>
vmap <silent> <leader>a:: :Tabularize /:\zs<CR>
nmap <silent> <leader>a, :Tabularize /,<CR>
vmap <silent> <leader>a, :Tabularize /,<CR>
nmap <silent> <leader>a,, :Tabularize /,\zs<CR>
vmap <silent> <leader>a,, :Tabularize /,\zs<CR>
nmap <silent> <leader>a<Bar> :Tabularize /<Bar><CR>
vmap <silent> <leader>a<Bar> :Tabularize /<Bar><CR>


" bundle/tagbar
" ------------------------------------------------------------------
let g:tagbar_autoclose = 1
let g:tagbar_compact = 1
let g:tagbar_previewwin_pos = 'rightbelow'

nmap <silent> <leader>tb :TagbarToggle<CR>


" bundle/tcomment_vim
" ------------------------------------------------------------------

nmap <silent> <C-/> :TComment<CR>

" bundle/ultisnips
" ------------------------------------------------------------------


" function! g:UltiSnips_Complete()
"     call UltiSnips_ExpandSnippet()
"     if g:ulti_expand_res == 0
"         if pumvisible()
"             return "\<C-n>"
"         else
"             call UltiSnips_JumpForwards()
"             if g:ulti_jump_forwards_res == 0
"                return "\<TAB>"
"             endif
"         endif
"     endif
"     return ""
" endfunction
"
" au BufEnter * exec "inoremap <silent> " . g:UltiSnipsExpandTrigger . " <C-R>=g:UltiSnips_Complete()<cr>"
" let g:UltiSnipsJumpForwardTrigger="<tab>"
" let g:UltiSnipsListSnippets="<c-e>"
" let g:UltiSnipsSnippetDirectories = ["UltiSnips", "ultisnips-snippets"]
"
"






" let g:current_path_for_nerd_init=expand('%:p:h')

" " Ultisnip
" " NOTE: <f1> otherwise it overrides <tab> forever
" let g:UltiSnipsExpandTrigger="<f1>"
" let g:UltiSnipsJumpForwardTrigger="<f1>"
" let g:UltiSnipsJumpBackwardTrigger="<c-k>"
" let g:did_UltiSnips_vim_after = 1



" bundle/undotree
" ------------------------------------------------------------------
let g:undotree_SetFocusWhenToggle = 1
let g:undotree_WindowLayout = 4

nmap <silent> <leader>ut :UndotreeToggle<CR>


" bundle/vim-airline
" ------------------------------------------------------------------
let g:airline_powerline_fonts = 1

" Enable the list of buffers
let g:airline#extensions#tabline#enabled = 1

" Show just the filename
let g:airline#extensions#tabline#fnamemod = ':t'


" bundle/vim-airline-themes
" ------------------------------------------------------------------
let g:airline_theme = 'murmur'


" bundle/vim-devicons
" ------------------------------------------------------------------

" bundle/vim-easymotion
" ------------------------------------------------------------------


" bundle/vim-easytags
" ------------------------------------------------------------------


" bundle/vim-expand-region
" ------------------------------------------------------------------


" bundle/vim-fugitive
" ------------------------------------------------------------------
nmap <silent> <leader>gs :Gstatus<CR>
nmap <silent> <leader>gd :Gdiff<CR>
nmap <silent> <leader>gc :Gcommit<CR>
nmap <silent> <leader>gb :Gblame<CR>
nmap <silent> <leader>gl :Glog<CR>
nmap <silent> <leader>gp :Git push<CR>
nmap <silent> <leader>gr :Gread<CR>
nmap <silent> <leader>gw :Gwrite<CR>
nmap <silent> <leader>ge :Gedit<CR>
" Mnemonic _i_nteractive
nmap <silent> <leader>gi :Git add -p %<CR>
nmap <silent> <leader>gg :SignifyToggle<CR>


" bundle/vim-gitgutter
" ------------------------------------------------------------------

let g:gitgutter_max_signs = 99999


" bundle/vim-monokai
" ------------------------------------------------------------------


" bundle/vim-multiple-cursors
" ------------------------------------------------------------------
let g:multi_cursor_start_key='<C-d>'
let g:multi_cursor_next_key='<C-d>'


" bundle/vim-pathogen
" ------------------------------------------------------------------


" bundle/vim-polyglot
" ------------------------------------------------------------------


" bundle/vim-rooter
" ------------------------------------------------------------------


"   let g:rooter_manual_only = 1
"   let g:rooter_change_directory_for_non_project_files = 0
"   let g:rooter_use_lcd = 1
"   let g:rooter_silent_chdir = 1
"   let g:rooter_patterns = ['Gemfile', 'package.json', 'bower.json', '.git', '.git/', '_darcs/', '.hg/', '.bzr/', '.svn/']


" bundle/vim-snippets
" ------------------------------------------------------------------


" bundle/vim-surround
" ------------------------------------------------------------------
" ," Surround a word with "quotes"
map ," ysiw"
vmap ," c"<C-R>""<ESC>

" ,' Surround a word with 'single quotes'
map ,' ysiw'
vmap ,' c'<C-R>"'<ESC>

" ,) or ,( Surround a word with (parens)
" The difference is in whether a space is put in
map ,( ysiw(
map ,) ysiw)
vmap ,( c( <C-R>" )<ESC>
vmap ,) c(<C-R>")<ESC>

" ,[ Surround a word with [brackets]
map ,] ysiw]
map ,[ ysiw[
vmap ,[ c[ <C-R>" ]<ESC>
vmap ,] c[<C-R>"]<ESC>

" ,{ Surround a word with {braces}
map ,} ysiw}
map ,{ ysiw{
vmap ,} c{ <C-R>" }<ESC>
vmap ,{ c{<C-R>"}<ESC>


" bundle/vim-table-mode
" ------------------------------------------------------------------


" bundle/vim-textobj-user
" ------------------------------------------------------------------


" bundle/YankRing.vim
" ------------------------------------------------------------------
let g:yankring_history_dir = '~/.subliminal-vim/tempdir'
let g:yankring_max_history = 100
let g:yankring_window_use_horiz = 0
let g:yankring_clipboard_monitor = 0
let g:yankring_manual_clipboard_check = 0

nmap <silent> <leader>ys :YRShow<CR>

" bundle/YouCompleteMe
" ------------------------------------------------------------------

let g:acp_enableAtStartup = 0

" enable completion from tags
let g:ycm_collect_identifiers_from_tags_files = 1

" remap Ultisnips for compatibility for YCM
" let g:UltiSnipsExpandTrigger = '<C-j>'
" let g:UltiSnipsJumpForwardTrigger = '<C-j>'
" let g:UltiSnipsJumpBackwardTrigger = '<C-k>'

" Enable omni completion.
autocmd FileType css setlocal omnifunc=csscomplete#CompleteCSS
autocmd FileType html,markdown setlocal omnifunc=htmlcomplete#CompleteTags
autocmd FileType javascript setlocal omnifunc=javascriptcomplete#CompleteJS
autocmd FileType python setlocal omnifunc=pythoncomplete#Complete
autocmd FileType xml setlocal omnifunc=xmlcomplete#CompleteTags
autocmd FileType ruby setlocal omnifunc=rubycomplete#Complete
autocmd FileType haskell setlocal omnifunc=necoghc#omnifunc
set tags=./tags;/,~/.vimtags

" Make tags placed in .git/tags file available in all levels of a repository
let gitroot = substitute(system('git rev-parse --show-toplevel'), '[\n\r]', '', 'g')

if gitroot != ''
    let &tags = &tags . ',' . gitroot . '/.git/tags'
endif


