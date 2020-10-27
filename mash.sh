#!/usr/bin/bash
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

VERSION="0.1.0a2"
BASEDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
FONTNAME="DejaVu Sans Mono for Powerline Nerd Font Complete Mono.ttf"

if [ "${BASEDIR}" == "/usr/bin" ]; then
    APPSTATE="intalled"
    SHAREDIR="/usr/share/mash"
    ICONDIR="/usr/share/icons"
    ICONPATH="${ICONDIR}/hicolor/22x22/apps/collagelabs-mash.png"
else
    APPSTATE="testing"
    BUILDDIR="${BASEDIR}/build"
    ICONDIR="${BUILDDIR}/icons"
    ICONPATH="${ICONDIR}/hicolor/22x22/apps/collagelabs-mash.png"
fi

if [ -f "${HOME}/.config/mash/app/metadata.conf" ]; then
    USERVERSION="$(cat "${HOME}/.config/mash/app/metadata.conf" | grep 'VERSION=' | awk -F'=' '{print $2}' | sed 's/"//g' )"
fi

if [ "${APPSTATE}" == "installed" ]; then
    ORIGINMETADATA="https://raw.githubusercontent.com/CollageLabs/mash/master/metadata.conf"
    ORIGINVERSION="$(curl -fsSL ${ORIGINMETADATA} | grep 'VERSION=' | awk -F'=' '{print $2}' | sed 's/"//g' )"

    if [ "${USERVERSION}" != "${VERSION}" ]; then

        TEXT="Thanks for using Mash. If you want to activate linters for your favourite languages, take a look at https://github.com/CollageLabs/mash for detailed instrucions on how to activate each one."

        zenity --info --text="${TEXT}" \
            --window-icon "${ICONPATH}" \
            --height 600 --width 600
    fi

    if [ "${ORIGINVERSION}" != "${VERSION}" ]; then
        TEXT="There's a new version of Mash available. You can go to the release page to download it (https://github.com/CollageLabs/mash/releases) or use your OS package manager to update."

        zenity --info --text="${TEXT}" \
        --window-icon "${ICONPATH}" \
        --height 600 --width 600
    fi
fi

if [ "${USERVERSION}" != "${VERSION}" ] || [ "${APPSTATE}" == "testing" ]; then
    echospaced "Creating folders ..."
    mkdir -p "${HOME}/.config/mash/recovery"
    mkdir -p "${HOME}/.config/mash/backups"
    mkdir -p "${HOME}/.config/mash/undo"
    mkdir -p "${HOME}/.config/mash/bin"
    mkdir -p "${HOME}/.config/mash/urxvt"
    mkdir -p "${HOME}/.config/mash/runtime"
    mkdir -p "${HOME}/.config/mash/plugins"
    mkdir -p "${HOME}/.config/mash/plug"
    mkdir -p "${HOME}/.config/mash/app"

    echospaced "Copying files ..."
    if [ "${APPSTATE}" == "testing" ]; then
        cp -rf "${BUILDDIR}/ui/search" "${HOME}/.config/mash/bin"
        cp -rf "${BUILDDIR}/ui/search.css" "${HOME}/.config/mash/bin"
        cp -rf "${BUILDDIR}/urxvt/src/rxvt" "${HOME}/.config/mash/bin"
        cp -rf "${BUILDDIR}/vim/src/vim" "${HOME}/.config/mash/bin"
        cp -rf "${BUILDDIR}/urxvt/src/urxvt.pm" "${HOME}/.config/mash/urxvt"
        cp -rf "${BUILDDIR}/vim/runtime" "${HOME}/.config/mash"
        cp -rf "${BUILDDIR}/plugins" "${HOME}/.config/mash"
        cp -rf "${BUILDDIR}/plug" "${HOME}/.config/mash"
        rsync -a --exclude "${BUILDDIR}/*" "${BASEDIR}/" "${HOME}/.config/mash/app"
        cp -rf "${BUILDDIR}/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
    else
        cp -rf "${SHAREDIR}/bin" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/urxvt" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/runtime" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/plugins" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/plug" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/app" "${HOME}/.config/mash"
        cp -rf "${SHAREDIR}/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
    fi

    echospaced "Compiling vimproc ..."
    cd "${HOME}/.config/mash/plugins/vimproc.vim" && make

    echospaced "Updating font cache ..."
    fc-cache -vr "${HOME}/.local/share/fonts"
fi

eval "$(tr '\0' '\n' < /proc/${$}/environ | grep '^DISPLAY=')"

env XENVIRONMENT="${HOME}/.config/mash/app/Xresources" \
    URXVT_PERL_LIB="${HOME}/.config/mash/app/extensions" \
    PERL5LIB="${HOME}/.config/mash/urxvt" \
    DISPLAY="${DISPLAY}" \
    ${HOME}/.config/mash/bin/rxvt \
        -icon "${ICONPATH}" \
        -name "mash" -e bash -c "stty -ixon susp undef; ${HOME}/.config/mash/bin/vim --servername mash-${$} -u ${HOME}/.config/mash/app/init.vim ${*}"
