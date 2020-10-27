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


function! PlugIsInstalled(plugin)
    if has_key(g:plugs, a:plugin) && isdirectory(g:plugs[a:plugin].dir)
        return 1
    endif
    return 0
endfunction

function! AutoPlugInstall()
    if !empty(filter(copy(g:plugs), '!isdirectory(v:val.dir)')) && exists(':PlugInstall')
        PlugInstall
        call system('nohup mash >/dev/null 2>&1 &')
        qall
    endif
endfunction

augroup auto_plug_install
    autocmd!
    autocmd VimEnter * call AutoPlugInstall()
augroup END