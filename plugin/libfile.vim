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


function! CloseFile()
    if &ft != 'nerdtree'
        if &mod
            let l:message = 'Do you want to save changes before closing?'
            let l:windowcmd = 'zenity --question --no-wrap'
            let l:windowcmd .= ' --text '''.l:message.''' '
            let l:windowcmd .= ' --extra-button "Close without saving"'
            let l:windowcmd .= ' --ok-label "Save"'
            let l:windowcmd .= ' --cancel-label "Cancel"'
            let l:windowcmd .= ' --title "Save?" --modal'
            let l:windowcmd .= ' --window-icon '.s:sv_window_icon
            let l:windowcmd .= ' 2>/dev/null'
            let l:question = system(l:windowcmd)

            " If empty, user chose Save or Cancel
            if empty(l:question)
                " If v:shell_error == 0, user chose Save
                if !v:shell_error
                    call SaveFile()
                else
                    return
                endif
            endif
        endif

        let l:totalbuffs = len(filter(range(1, bufnr('$')), 'buflisted(v:val)'))

        if l:totalbuffs == 1
            execute ":qall!"
        else
            execute ':bp!'
            execute ':bw!#'
            execute ':startinsert!'
        endif
    endif
endfunction

function! SaveFile()
    if empty(expand('%:t'))
        call SaveFileAs()
    else
        execute ':w!'
        execute ':startinsert!'
    endif
endfunction

function! SaveFileAs()
    let l:windowcmd = 'zenity --file-selection'
    let l:windowcmd .= ' --save'
    let l:windowcmd .= ' --title "Enter filename" --modal'
    let l:windowcmd .= ' --window-icon  '.s:sv_window_icon
    let l:windowcmd .= ' 2>/dev/null | xargs printf'
    let l:savefile = system(l:windowcmd)

    if !empty(glob(l:savefile))
        let l:filename = split(l:savefile, '/')[-1]
        let l:folder = split(l:savefile, '/')[-2]
        let l:existsmessage = 'A file named "'.l:filename.'" already exists'
        let l:existsmessage .= ' in "'.l:folder.'".\n\n'
        let l:existsmessage .= ' Do you want to replace it?'
        let l:windowcmd = 'zenity --question --no-wrap'
        let l:windowcmd .= ' --text '''.l:existsmessage.''' '
        let l:windowcmd .= ' --title "Replace?" --modal'
        let l:windowcmd .= ' --window-icon  '.s:sv_window_icon
        let l:windowcmd .= ' 2>/dev/null'
        let l:question = system(l:windowcmd)
    endif

    if !v:shell_error
        execute ':w! '.l:savefile
    endif
    execute ':startinsert!'
endfunction

function! OpenFile()
    let l:windowcmd = 'zenity --file-selection'
    let l:windowcmd .= ' --title "Open file" --modal'
    let l:windowcmd .= ' --window-icon  '.s:sv_window_icon
    let l:windowcmd .= ' 2>/dev/null'
    let l:openfile = system(l:windowcmd)
    execute ':e '.l:openfile
endfunction