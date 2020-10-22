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

" ----------------------------------------------------------------------------
" SEARCH FUNCTIONS
" ----------------------------------------------------------------------------


let g:sv_py_path = '/usr/bin/python'
let g:sv_py_search = '~/.config/subliminal-view/app/ui/search.py'
let g:sv_py_searchreplace = '~/.config/subliminal-view/app/ui/searchreplace.py'
let g:sv_py_searchfiles = '~/.config/subliminal-view/app/ui/searchfiles.py'

map <silent> <C-f> :call system(g:sv_py_path.' '.g:sv_py_search.' '.v:servername.' &')<CR>
map! <silent> <C-f> <Esc>:call system(g:sv_py_path.' '.g:sv_py_search.' '.v:servername.' &')<CR>

map <silent> <C-h> :call system(g:sv_py_path.' '.g:sv_py_searchreplace.' '.v:servername.' &')<CR>
map! <silent> <C-h> <Esc>:call system(g:sv_py_path.' '.g:sv_py_searchreplace.' '.v:servername.' &')<CR>

map <silent> <Esc>[70;5~ :call system(g:sv_py_path.' '.g:sv_py_searchfiles.' '.v:servername.' &')<CR>
map! <silent> <Esc>[70;5~ <Esc>:call system(g:sv_py_path.' '.g:sv_py_searchfiles.' '.v:servername.' &')<CR>

" bundle/unite.vim
" ------------------------------------------------------------------

if isdirectory(g:plugs['unite.vim'].dir)
    call unite#filters#matcher_default#use(['matcher_regexp'])
    call unite#filters#sorter_default#use(['sorter_rank'])
endif

map <silent> <C-p> :Unite -start-insert -no-split -auto-preview -buffer-name=files file_rec/async<CR>
map! <silent> <C-p> <Esc>:Unite -start-insert -no-split -auto-preview -buffer-name=files file_rec/async<CR>

map <silent> <Esc>[80;5~ :Unite -no-split menu:file menu:edit<CR>
map! <silent> <Esc>[80;5~ <Esc>:Unite -no-split menu:file menu:edit<CR>

" map <silent> <Esc>[70;5~ :Unite -auto-preview -start-insert -no-split -buffer-name=files grep:.<CR>
" map! <silent> <Esc>[70;5~ <Esc>:Unite -start-insert -no-split -auto-preview -buffer-name=files grep:.<CR>

autocmd FileType unite call s:unite_settings()

function! s:unite_settings()
    syntax manual
    set syntax=off
    set noinsertmode
    map! <silent> <buffer> <CR>   <Esc><Plug>(unite_do_default_action)<BAR>:set syntax=on<BAR>:star!<CR>
    map! <silent> <buffer> <LeftMouse>   <Esc><Plug>(unite_do_default_action)<BAR>:set syntax=on<BAR>:star!<CR>
    map <silent> <buffer> <CR>   <Plug>(unite_do_default_action)<BAR>:set syntax=on<BAR>:star!<CR>
    map <silent> <buffer> <LeftMouse>   <Plug>(unite_do_default_action)<BAR>:set syntax=on<BAR>:star!<CR>
endfunction

" Go to symbol
" nnoremap <silent> ;t
"       \ :<C-u>UniteWithCursorWord -buffer-name=tag tag tag/include<CR>

" Use ag (the silver searcher)
" https://github.com/ggreer/the_silver_searcher
let g:unite_source_grep_command = 'ag'
let g:unite_source_grep_default_opts = '-i --vimgrep --hidden --ignore ' .
    \ '''.hg'' --ignore ''.svn'' --ignore ''.git'' --ignore ''.bzr'''
let g:unite_source_grep_recursive_opt = ''
let g:unite_source_file_rec_max_cache_files = 0
let g:unite_source_history_yank_enable = 1
let g:unite_source_rec_async_command = ['ag', '--follow', '--nocolor',
    \ '--nogroup', '--hidden', '-g', '']

let g:unite_source_menu_menus = {
    \     'file' : '',
    \     'edit' : '',
    \     'selection' : '',
    \     'find' : '',
    \     'view' : '',
    \     'goto' : '',
    \     'tools' : '',
    \     'project' : '',
    \     'preferences' : '',
    \     'help' : ''
    \ }

let g:unite_source_menu_menus.file = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['  New File                                     Ctrl+N', 'execute "normal \<C-n>"'],
              \ ['  Open File...                                 Ctrl+O', 'execute "normal \<C-o>"'],
              \ ['  Open Folder...                                     ', 'execute "normal \<C-o>"'],
              \ ["  Open Recent                                       \uf0da", 'execute "normal \<C-o>"'],
              \ ["  Reopen with encoding                              \uf0da", 'execute "normal \<C-o>"'],
              \ ["  New view into File                                \uf0da", 'execute "normal \<C-o>"'],
              \ ["  Save                                         Ctrl+S", 'execute "normal \<C-o>"'],
              \ ["  Save with encoding                                \uf0da", 'execute "normal \<C-o>"'],
              \ ["  Save As...                             Shift+Ctrl+S", 'execute "normal \<C-o>"'],
              \ ["  Save All                                           ", 'execute "normal \<C-o>"'],
              \ ["  New Window                             Shift+Ctrl+N", 'execute "normal \<C-o>"'],
              \ ["  Close Window                           Shift+Ctrl+W", 'execute "normal \<C-o>"'],
              \ ["  Close File                                   Ctrl+W", 'execute "normal \<C-w>"'],
              \ ["  Revert File                                        ", ''],
              \ ["  Close All Files                                    ", ''],
              \ ["  Quit                                         Ctrl+Q", 'execute "normal \<C-q>"'],
          \ ],
      \ }

let g:unite_source_menu_menus.edit = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['Hola', 'chao'],
          \ ],
      \ }

let g:unite_source_menu_menus.selection = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.find = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.view = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.goto = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.tools = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.project = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.preferences = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }

let g:unite_source_menu_menus.help = {
      \     'description' : '',
      \     'command_candidates' : [
              \ ['', ''],
          \ ],
      \ }


" bundle/vim-easygrep
" ----------------------------------------------------------------------------

let g:EasyGrepCommand = 1
set grepprg=ag\ --vimgrep

" bundle/auto-pairs
" ----------------------------------------------------------------------------


" bundle/goyo.vim
" ----------------------------------------------------------------------------


" bundle/nerdtree
" ----------------------------------------------------------------------------

let NERDTreeMinimalUI = 1
let NERDTreeShowHidden = 1
let NERDTreeMouseMode = 3
let NERDTreeIgnore = ['\.py[cd]$', '\~$', '\.swo$', '\.swp$', '^\.git$',
            \ '^\.hg$', '^\.svn$', '\.bzr$']

" bundle/syntastic
" ----------------------------------------------------------------------------

" show the error list automatically
let g:syntastic_check_on_open = 1
let g:syntastic_error_symbol = "\uf12a"
let g:syntastic_style_error_symbol = "\uf12a"
let g:syntastic_warning_symbol = "\uf12a"
let g:syntastic_style_warning_symbol = "\uf12a"
let g:syntastic_stl_format = "%E{%e Errors}%B{, }%W{%w Warnings}"

" Python
let g:syntastic_python_checkers = ['python', 'pep8', 'pylint', 'pyflakes', 'pydocstyle']
let g:syntastic_python_python_exec = '~/.config/subliminal-view/sandboxes/python/bin/python'
let g:syntastic_python_pep8_exec = '~/.config/subliminal-view/sandboxes/python/bin/pep8'
let g:syntastic_python_pylint_exec = '~/.config/subliminal-view/sandboxes/python/bin/pylint'
let g:syntastic_python_pyflakes_exec = '~/.config/subliminal-view/sandboxes/python/bin/pyflakes'
let g:syntastic_python_pydocstyle_exec = '~/.config/subliminal-view/sandboxes/python/bin/pydocstyle'

" Ruby
let g:syntastic_ruby_checkers = ['mri', 'rubocop']
let g:syntastic_ruby_mri_exec = '~/.config/subliminal-view/sandboxes/ruby/bin/ruby'
let g:syntastic_ruby_rubocop_exec = '~/.config/subliminal-view/sandboxes/ruby/bin/rubocop'
let g:syntastic_ruby_rubocop_args = '--cache false'
let $GEM_PATH .= ':~/.config/subliminal-view/sandboxes/ruby'

" Shell
let g:syntastic_sh_checkers = ['sh', 'checkbashisms', 'shellcheck']
let g:syntastic_sh_sh_exec = '/usr/bin/bash'
let g:syntastic_sh_checkbashisms_exec = '/usr/bin/checkbashisms'
let g:syntastic_sh_shellcheck_exec = '/usr/bin/shellcheck'

" Javascript
let g:syntastic_javascript_checkers = ['jshint']
let g:syntastic_javascript_jshint_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/jshint'

" Go
let g:syntastic_go_checkers = ['go', 'gofmt', 'golint']
let g:syntastic_go_go_exec = '/usr/bin/go'
let g:syntastic_go_gofmt_exec = '/usr/bin/gofmt'
let g:syntastic_go_golint_exec = '~/.config/subliminal-view/sandboxes/go/bin/golint'

" Markdown
let g:syntastic_markdown_checkers = ['mdl']
let g:syntastic_markdown_mdl_exec =  '~/.config/subliminal-view/sandboxes/ruby/bin/mdl'

" RST
let g:syntastic_rst_checkers = ['rst2pseudoxml']
let g:syntastic_rst_rst2pseudoxml_exec =  '~/.config/subliminal-view/sandboxes/python/bin/rst2pseudoxml.py'

" HTML
let g:syntastic_html_checkers = ['tidy']
let g:syntastic_html_tidy_exec =  '/usr/bin/tidy'

" XHTML
let g:syntastic_xhtml_checkers = ['tidy']
let g:syntastic_xhtml_tidy_exec =  '/usr/bin/tidy'

" XML
let g:syntastic_xml_checkers = ['xmllint']
let g:syntastic_xml_xmllint_exec =  '/usr/bin/xmllint'

" YAML
let g:syntastic_yaml_checkers = ['yamllint']
let g:syntastic_yaml_yamllint_exec =  '~/.config/subliminal-view/sandboxes/python/bin/yamllint'

" CSS
let g:syntastic_css_checkers = ['csslint']
let g:syntastic_css_csslint_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/csslint'

" LESS
let g:syntastic_less_checkers = ['lessc']
let g:syntastic_less_lessc_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/lessc'

" SASS
let g:syntastic_sass_checkers = ['sass_lint']
let g:syntastic_sass_sass_lint_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/sass-lint'

" SCSS
let g:syntastic_scss_checkers = ['sass_lint']
let g:syntastic_scss_sass_lint_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/sass-lint'

" C
let g:syntastic_c_checkers = ['gcc']
let g:syntastic_c_gcc_exec = '/usr/bin/gcc'

" Objective C
let g:syntastic_objc_checkers = ['gcc']
let g:syntastic_objc_gcc_exec = '/usr/bin/gcc'

" C++
let g:syntastic_cpp_checkers = ['gcc']
let g:syntastic_cpp_gcc_exec = '/usr/bin/gcc'

" Objective C++
let g:syntastic_objcpp_checkers = ['gcc']
let g:syntastic_objcpp_gcc_exec = '/usr/bin/gcc'

" C#
let g:syntastic_cs_checkers = ['mcs']
let g:syntastic_cs_mcs_exec = '/usr/bin/mcs'

" Vim
let g:syntastic_vim_checkers = ['vint']
let g:syntastic_vim_vint_exec = '~/.config/subliminal-view/sandboxes/python/bin/vint'

" SQL
let g:syntastic_sql_checkers = ['sqlint']
let g:syntastic_sql_sqlint_exec = '~/.config/subliminal-view/sandboxes/ruby/bin/sqlint'

" PHP
let g:syntastic_php_checkers = ['php']
let g:syntastic_php_php_exec = '/usr/bin/php'

" Perl
let g:syntastic_enable_perl_checker = 1
let g:syntastic_perl_checkers = ['perl']
let g:syntastic_perl_perl_exec = '/usr/bin/perl'

" Rust
let g:syntastic_rust_checkers = ['rustc']
let g:syntastic_rust_rustc_exec = '/usr/bin/rustc'

" Docker
let g:syntastic_dockerfile_checkers = ['dockerfile_lint']
let g:syntastic_dockerfile_dockerfile_lint_exec = '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/dockerfile_lint'
let g:syntastic_dockerfile_dockerfile_lint_args = '-r ~/.config/subliminal-view/sandboxes/node/node_modules/dockerfile_lint/config/default_rules.yaml'

" JSON
let g:syntastic_json_checkers = ['jsonlint']
let g:syntastic_json_jsonlint_exec =  '~/.config/subliminal-view/sandboxes/node/node_modules/.bin/jsonlint'

" PO
let g:syntastic_po_checkers = ['msgfmt']
let g:syntastic_po_msgfmt_exec =  '/usr/bin/msgfmt'

" Rust
let g:syntastic_rust_checkers = ['rustc']
let g:syntastic_rust_rustc_exec =  '/usr/bin/rustc'

" bundle/tcomment_vim
" ------------------------------------------------------------------

let g:tcommentMaps = 0
map <silent> <C-_> :TComment<CR>i
map! <silent> <C-_> <Esc>:TComment<CR>i

" bundle/vim-airline
" ------------------------------------------------------------------

let g:airline_theme = 'subliminal'
let g:airline_powerline_fonts = 1
let g:airline_left_sep = "\ue0b8"
let g:airline_left_alt_sep = "\ue0b9"
let g:airline_right_sep = "\ue0ba"
let g:airline_right_alt_sep = "\ue0bb"

if !exists('g:airline_symbols')
    let g:airline_symbols = {}
endif

let g:airline_symbols.modified = "  \u2022"


" Enable the list of buffers
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#show_tabs = 0
let g:airline#extensions#tabline#show_tab_type = 0

let g:airline#extensions#tabline#formatter = 'subliminal'
let g:airline#extensions#tabline#left_sep = "\ue0b8"
let g:airline#extensions#tabline#left_alt_sep = "\ue0b9"
let g:airline#extensions#tabline#buffer_idx_mode = 1

let g:airline#extensions#whitespace#trailing_format = 'trailing[%s]'
let g:airline#extensions#whitespace#mixed_indent_format = 'mixed-indent[%s]'
let g:airline#extensions#whitespace#long_format = 'long[%s]'
let g:airline#extensions#whitespace#mixed_indent_file_format = 'mix-indent-file[%s]'

let g:airline#extensions#default#layout = [
            \ ['a', 'b', 'warning', 'error', 'c'], ['x', 'y', 'z']
            \ ]

let g:airline_exclude_filetypes = ['nerdtree', 'unite']

" bundle/vim-devicons
" ------------------------------------------------------------------

let g:webdevicons_enable_airline_tabline = 0
let g:webdevicons_conceal_nerdtree_brackets = 1
let g:WebDevIconsUnicodeGlyphDoubleWidth = 0
let g:NERDTreeUpdateOnCursorHold = 0
let g:DevIconsEnableFoldersOpenClose = 1
let g:WebDevIconsUnicodeDecorateFolderNodes = 1
let g:WebDevIconsUnicodeDecorateFolderNodesDefaultSymbol = "\uf114"
let g:DevIconsDefaultFolderOpenSymbol = "\uf115"
let g:WebDevIconsNerdTreeAfterGlyphPadding = ''

" bundle/vim-easytags
" ------------------------------------------------------------------

let g:easytags_async = 1
let g:easytags_file = '~/.config/subliminal-view/vimtags'
let g:easytags_include_members = 1
let g:easytags_auto_highlight = 0
let g:easytags_resolve_links = 1
let g:easytags_suppress_report = 1
let g:easytags_suppress_ctags_warning = 1

" bundle/vim-gitgutter
" ------------------------------------------------------------------

let g:gitgutter_map_keys = 0
let g:gitgutter_max_signs = 99999
let g:gitgutter_sign_added = "\uf067"
let g:gitgutter_sign_modified = "\uf142"
let g:gitgutter_sign_removed = "\uf068"
let g:gitgutter_sign_modified_removed = "\uf068"

" bundle/vim-multiple-cursors
" ------------------------------------------------------------------

let g:multi_cursor_normal_maps = {}
let g:multi_cursor_insert_maps = {}
let g:multi_cursor_visual_maps = {}

let g:multi_cursor_start_key = '<C-d>'
let g:multi_cursor_next_key = '<C-d>'

map! <silent> <C-d> <Esc>viw

highlight link multiple_cursors_cursor Visual
highlight link multiple_cursors_visual Visual

map! <silent> <Esc>[1;3R <Esc>b"xyw:execute ':MultipleCursorsFind '.@x<CR>


" bundle/vim-polyglot
" ------------------------------------------------------------------


" bundle/neocomplete
" ------------------------------------------------------------------

let g:neocomplete#enable_at_startup = 1
let g:neocomplete#enable_smart_case = 1
let g:neocomplete#enable_auto_delimiter = 1
let g:neocomplete#max_list = 15
let g:neocomplete#force_overwrite_completefunc = 1

if !exists('g:neocomplete#sources#omni#input_patterns')
    let g:neocomplete#sources#omni#input_patterns = {}
endif

let g:neocomplete#sources#omni#input_patterns.c='[^.[:digit:] *\t]\%(\.\|->\)\%(\h\w*\)\?'
let g:neocomplete#sources#omni#input_patterns.cpp='[^.[:digit:] *\t]\%(\.\|->\)\%(\h\w*\)\?\|\h\w*::\%(\h\w*\)\?'
let g:neocomplete#sources#omni#input_patterns.xml='<[^>]*'
let g:neocomplete#sources#omni#input_patterns.html='<[^>]*'
let g:neocomplete#sources#omni#input_patterns.markdown='<[^>]*'
let g:neocomplete#sources#omni#input_patterns.css='^\s\+\w+\|\w+[):;]?\s\+\|[@!]'
let g:neocomplete#sources#omni#input_patterns.less='^\s\+\w+\|\w+[):;]?\s\+\|[@!]'
let g:neocomplete#sources#omni#input_patterns.javascript='[^. \t]\.\%(\h\w*\)\?'
let g:neocomplete#sources#omni#input_patterns.json='[^. \t]\.\%(\h\w*\)\?'
let g:neocomplete#sources#omni#input_patterns.python='\%([^. \t]\.\|^\s*@\|^\s*from\s.\+import \|^\s*from \|^\s*import \)\w*'
let g:neocomplete#sources#omni#input_patterns.python3='\%([^. \t]\.\|^\s*@\|^\s*from\s.\+import \|^\s*from \|^\s*import \)\w*'
let g:neocomplete#sources#omni#input_patterns.ruby='[^. *\t]\.\w*\|\h\w*::'
let g:neocomplete#sources#omni#input_patterns.php='[^. \t]->\%(\h\w*\)\?\|\h\w*::\%(\h\w*\)\?'
let g:neocomplete#sources#omni#input_patterns.go='\h\w*\%.'
let g:neocomplete#sources#omni#input_patterns.perl='\h\w*->\h\w*\|\h\w*::'
let g:neocomplete#sources#omni#input_patterns.java='\%(\h\w*\|)\)\.'

autocmd FileType css setlocal omnifunc=csscomplete#CompleteCSS
autocmd FileType html,markdown setlocal omnifunc=htmlcomplete#CompleteTags
autocmd FileType javascript setlocal omnifunc=javascriptcomplete#CompleteJS
" autocmd FileType python setlocal omnifunc=pythoncomplete#Complete
autocmd FileType ruby setlocal omnifunc=rubycomplete#Complete
autocmd FileType xml setlocal omnifunc=xmlcomplete#CompleteTags


" bundle/neosnippets
" ------------------------------------------------------------------



