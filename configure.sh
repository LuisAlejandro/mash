#!/usr/bin/env bash
#   This file is part of Mash
#   Copyright (c) 2016-2020, Mash Developers
#
#   Please refer to CONTRIBUTORS.md for a complete list of Copyright
#   holders.
#
#   Mash is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   Mash is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see <http://www.gnu.org/licenses/>.

set -ex

function echospaced() {
    printf "\n# %s\n" "${1}"
}

ICONSIZES="16 22 32 48 64 128 256 512"
FONTNAME="DejaVu Sans Mono for Powerline Nerd Font Complete Mono.ttf"

APPDIR="${HOME}/.config/mash/app"

echospaced "Creating folders ..."
mkdir -vp "${HOME}/.config/mash/recovery"
mkdir -vp "${HOME}/.config/mash/backups"
mkdir -vp "${HOME}/.config/mash/undo"
mkdir -vp "${HOME}/.local/share/fonts"
mkdir -vp "${HOME}/.local/bin"

echospaced "Copying content ..."
cp -vf "${HOME}/.config/mash/app/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
cp -vf "${HOME}/.config/mash/app/mash.sh" "${HOME}/.local/bin/mash"

echospaced "Updating font cache ..."
fc-cache -vr "${HOME}/.local/share/fonts"

echospaced "Configuring executables ..."
if [ ! -f "${HOME}/.bashrc" ]; then
    touch "${HOME}/.bashrc"
fi

if ! grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
    echo 'PATH="${PATH}:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
fi

echospaced "Creating folders ..."
mkdir -vp "${HOME}/.config/mash/recovery"
mkdir -vp "${HOME}/.config/mash/backups"
mkdir -vp "${HOME}/.config/mash/undo"
mkdir -vp "${HOME}/.config/mash/bin"
mkdir -vp "${HOME}/.config/mash/urxvt"
mkdir -vp "${HOME}/.config/mash/runtime"
mkdir -vp "${HOME}/.config/mash/plugins"
mkdir -vp "${HOME}/.config/mash/plug"
mkdir -vp "${HOME}/.config/mash/app"

echospaced "Copying files ..."
cp -rf "${APPDIR}/bin" "${HOME}/.config/mash"
cp -rf "${APPDIR}/urxvt" "${HOME}/.config/mash"
cp -rf "${APPDIR}/runtime" "${HOME}/.config/mash"
cp -rf "${APPDIR}/plugins" "${HOME}/.config/mash"
cp -rf "${APPDIR}/plug" "${HOME}/.config/mash"
cp -rf "${APPDIR}/plugins/mash/." "${HOME}/.config/mash/app"

echospaced "Updating font cache ..."
cp -f "${APPDIR}/fonts/DejaVu Sans Mono Nerd Font Complete Mono.ttf" "${HOME}/.local/share/fonts/"
cp -f "${APPDIR}/fonts/fontawesome-webfont.ttf" "${HOME}/.local/share/fonts/"
fc-cache -vr "${HOME}/.local/share/fonts"