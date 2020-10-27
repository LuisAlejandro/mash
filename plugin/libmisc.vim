"   This file is part of Mash
"   Copyright (c) 2016-2020, Mash Developers
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


let s:sv_window_icon = '/usr/share/icons/hicolor/22x22/apps/collagelabs-mash.png'

function! EchoSyntasticText()
    if !exists('b:syntastic_private_messages')
        let b:syntastic_private_messages = {}
    endif

    if has_key(b:syntastic_private_messages, line('.'))
        return b:syntastic_private_messages[line('.')][0].text
    endif

    return expand('%F%m')
endfunction

function! AirlineInit()
    let g:airline_section_a = airline#section#create(['branch'])
    let g:airline_section_b = airline#section#create(['hunks'])
    let g:airline_section_warning = airline#section#create(['whitespace'])
    let g:airline_section_error = airline#section#create(['syntastic'])
    let g:airline_section_c = airline#section#create(['%{EchoSyntasticText()}'])
    let g:airline_section_x = airline#section#create(['readonly', 'filetype'])
    let g:airline_section_y = airline#section#create(['ffenc'])
    let g:airline_section_z = airline#section#create(['Line %3l, Column %3v'])
endfunction

function! ProjectFilePath(short)
    let l:path = fnamemodify(expand('%'), ':p:h')
    let l:root = getcwd()

    let l:root = substitute(l:path, '^' . l:root . '/', '', '')
    let l:root = substitute(l:root, '^' . $HOME, '~', '')

    if exists('b:git_dir')
        let l:root = substitute(l:root, '^' . b:git_dir, '', '')
        let l:project = fnamemodify(b:git_dir, ':h:t')

        " only return project name
        if a:short || winwidth(0) < 60
            return l:project
        endif

        " otherwise also add the path
        if fnamemodify(b:git_dir, ':h') == l:root
            let l:root = l:project
        else
            let l:root .= ' @ ' . l:project
        endif
    endif

    return l:root
endfunction

augroup auto_refresh_file
    autocmd!
    autocmd CursorHold,CursorHoldI * checktime
augroup END

augroup change_airline
    autocmd!
    autocmd User AirlineAfterInit call AirlineInit()
augroup END