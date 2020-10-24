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


" Menu bar
" --------

map <silent> <Esc>f :Unite menu:file<CR>
map! <silent> <Esc>f <Esc>:Unite menu:file<CR>


" Interface
" ----------------------------------------------------------------------------

" `ctrl-q` | Exit all windows
map <silent> <C-q> :call system('pkill -P $(pgrep -d, urxvt)')<CR>
map! <silent> <C-q> <Esc>:call system('pkill -P $(pgrep -d, urxvt)')<CR>

" `ctrl-q` | New window
map <silent> <Esc>[78;5~ :call system('mash')<CR>
map! <silent> <Esc>[78;5~ <Esc>:call system('mash')<CR>

" Close window
map <silent> <Esc>[87;5~ :qall!<CR>
map! <silent> <Esc>[87;5~ <Esc>:qall!<CR>

" Open file
map <silent> <C-o> :call OpenFile()<CR>
map! <silent> <C-o> <Esc>:call OpenFile()<CR>

" Open last closed tab
map <silent> <Esc>[84;5~ :e#<CR>
map! <silent> <Esc>[84;5~ <Esc>:e#<CR>

" Open a new unnamed file
map <silent> <C-n> :enew<CR>
map! <silent> <C-n> <Esc>:enew<CR>

" Save file
map <silent> <C-s> :call SaveFile()<CR>
map! <silent> <C-s> <Esc>:call SaveFile()<CR>

" Save file as
map <silent> <Esc>[83;5~ :call SaveFileAs()<CR>
map! <silent> <Esc>[83;5~ <Esc>:call SaveFileAs()<CR>

" Close file
map <silent> <C-w> :call CloseFile()<CR>
map! <silent> <C-w> <Esc>:call CloseFile()<CR>
map <silent> <Esc>[1;5S :call CloseFile()<CR>
map! <silent> <Esc>[1;5S <Esc>:call CloseFile()<CR>

" Show/Hide sidebar
map <silent> <C-k><C-b> :NERDTreeToggle<CR>
map! <silent> <C-k><C-b> <Esc>:NERDTreeToggle<CR>

" Distraction free mode
map <silent> <Esc>[23;2~ :Goyo<CR>
map! <silent> <Esc>[23;2~ <Esc>:Goyo<CR>

" Undo
map! <silent> <C-z> <Esc>:undo<BAR>:star!<CR>
map <silent> <C-z> :undo<BAR>:star!<CR>
map! <silent> <C-u> <Esc>:undo<BAR>:star!<CR>
map <silent> <C-u> :undo<BAR>:star!<CR>

" Redo
map! <silent> <C-y> <Esc>:redo<BAR>:star!<CR>
map <silent> <C-y> :redo<BAR>:star!<CR>
map! <silent> <Esc>[90;5~ <Esc>:redo<BAR>:star!<CR>
map <silent> <Esc>[90;5~ :redo<BAR>:star!<CR>
map! <silent> <Esc>[85;5~ <Esc>:redo<BAR>:star!<CR>
map <silent> <Esc>[85;5~ :redo<BAR>:star!<CR>

" Navigate between tabs
map <silent> <Esc>1              <Plug>AirlineSelectTab1<BAR>:star!<CR>
map <silent> <Esc>2              <Plug>AirlineSelectTab2<BAR>:star!<CR>
map <silent> <Esc>3              <Plug>AirlineSelectTab3<BAR>:star!<CR>
map <silent> <Esc>4              <Plug>AirlineSelectTab4<BAR>:star!<CR>
map <silent> <Esc>5              <Plug>AirlineSelectTab5<BAR>:star!<CR>
map <silent> <Esc>6              <Plug>AirlineSelectTab6<BAR>:star!<CR>
map <silent> <Esc>7              <Plug>AirlineSelectTab7<BAR>:star!<CR>
map <silent> <Esc>8              <Plug>AirlineSelectTab8<BAR>:star!<CR>
map <silent> <Esc>9              <Plug>AirlineSelectTab9<BAR>:star!<CR>
map <silent> <Esc>[27;5;9~       <Plug>AirlineSelectPrevTab<BAR>:star!<CR>
map <silent> <Esc>[27;6;9~       <Plug>AirlineSelectNextTab<BAR>:star!<CR>

map! <silent> <Esc>1              <Esc><Plug>AirlineSelectTab1<BAR>:star!<CR>
map! <silent> <Esc>2              <Esc><Plug>AirlineSelectTab2<BAR>:star!<CR>
map! <silent> <Esc>3              <Esc><Plug>AirlineSelectTab3<BAR>:star!<CR>
map! <silent> <Esc>4              <Esc><Plug>AirlineSelectTab4<BAR>:star!<CR>
map! <silent> <Esc>5              <Esc><Plug>AirlineSelectTab5<BAR>:star!<CR>
map! <silent> <Esc>6              <Esc><Plug>AirlineSelectTab6<BAR>:star!<CR>
map! <silent> <Esc>7              <Esc><Plug>AirlineSelectTab7<BAR>:star!<CR>
map! <silent> <Esc>8              <Esc><Plug>AirlineSelectTab8<BAR>:star!<CR>
map! <silent> <Esc>9              <Esc><Plug>AirlineSelectTab9<BAR>:star!<CR>
map! <silent> <Esc>[27;5;9~       <Esc><Plug>AirlineSelectPrevTab<BAR>:star!<CR>
map! <silent> <Esc>[27;6;9~       <Esc><Plug>AirlineSelectNextTab<BAR>:star!<CR>

" Save all tabs
map! <silent> <C-e> <Esc>:wa!<CR>


" Text edition
" ------------

" Select all document
map! <silent> <C-a> <Esc>ggVG
map <silent> <C-a> ggVG


" Select with Shift + cursor keys
map! <silent> <S-Up>        <Esc>v<Up>
map <silent> <S-Up>        <Up>
map! <silent> <S-Down>      <Esc>v<Down>
map <silent> <S-Down>      <Down>
map! <silent> <S-Left>      <Esc>v<Left>
map <silent> <S-Left>      <Left>
map! <silent> <S-Right>     <Esc><Right>v<Right>
map <silent> <S-Right>     <Right>

map! <silent> <S-End>         <Esc>v<End>
map  <silent> <S-End>         <End>
map! <silent> <S-Home>        <Esc>v<Home>
map  <silent> <S-Home>        <Home>

map! <silent> <S-PageUp>       <Esc>v<PageUp>
map <silent> <S-PageUp>        <PageUp>
map! <silent> <S-PageDown>     <Esc>v<PageDown>
map <silent> <S-PageDown>      <PageDown>

" Move a block or line of text up or down
map! <silent> <Esc>[1;6A    <Esc>:m-2<BAR>:star!<CR>
map <silent> <Esc>[1;6A    :m'<-2<CR>`>my`<mzgv`yo`z
map! <silent> <Esc>[1;6B    <Esc>:m+<BAR>:star!<CR>
map <silent> <Esc>[1;6B    :m'>+<CR>`<my`>mzgv`yo`z

" Duplicate the selection
map! <silent> <Esc>[68;5~   <Esc>yyp<BAR>:star!<CR>
map  <silent> <Esc>[68;5~   yp

" Indent a line or block of code
imap <silent> <Tab>         <Esc>>>:star!<CR>
map <silent> <Tab>          >gv

" Deindent a line or block of code
map! <silent> <S-Tab>       <Esc><<:star!<CR>
map <silent> <S-Tab>       <gv

" Copy
map! <silent> <C-c>         <Esc>"xyy:call system('xclip -i -sel clipboard', @x)<BAR>:star!<CR>
map <silent> <C-c>         "xy:call system('xclip -i -sel clipboard', @x)<BAR>:star!<CR>

" Cut
map! <silent> <C-x>         <Esc>"xdd:call system('xclip -i -sel clipboard', @x)<BAR>:star!<CR>
map <silent> <C-x>         "xygvd:call system('xclip -i -sel clipboard', @x)<BAR>:star!<CR>

" Paste
map! <silent> <C-v>         <Esc>:let @x=system('xclip -o -sel clipboard')<CR>"xp<BAR>:star!<CR>
map <silent> <C-v>         :let @x=system('xclip -o -sel clipboard')<CR>"xp<BAR>:star!<CR>

" Windows (splits) --------------------------------------------------

