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

SHAREDIR="/usr/share/mash"
ICONDIR="/usr/share/icons"
VERSION="0.1.0a1a0"
ORIGINMETADATA="https://raw.githubusercontent.com/CollageLabs/mash/master/metadata.conf"
ORIGINVERSION="$(curl -fsSL ${ORIGINMETADATA} | grep 'VERSION=' | awk -F'=' '{print $2}' | sed 's/"//' )"

if [ -f "${HOME}/.config/mash/metadata.conf" ]; then
    USERVERSION="$(cat "${HOME}/.config/mash/metadata.conf" | grep 'VERSION=' | awk -F'=' '{print $2}' | sed 's/"//' )"
fi

if [ "${USERVERSION}" != "${VERSION}" ]; then

    # zenity

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
    cp -rf "${SHAREDIR}/metadata.conf" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/bin" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/urxvt" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/runtime" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/plugins" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/plug" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/app" "${HOME}/.config/mash"

    echospaced "Updating font cache ..."
    cp -f "${SHAREDIR}/fonts/DejaVu Sans Mono Nerd Font Complete Mono.ttf" "${HOME}/.local/share/fonts/"
    cp -f "${SHAREDIR}/fonts/fontawesome-webfont.ttf" "${HOME}/.local/share/fonts/"
    fc-cache -vr "${HOME}/.local/share/fonts"

    echospaced "Configuring executables ..."
    if [ ! -f "${HOME}/.bashrc" ]; then
        touch "${HOME}/.bashrc"
    fi

    if ! grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
        echo 'PATH="${PATH}:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
    fi
fi

if [ "${ORIGINVERSION}" != "${VERSION}" ]; then
    # zenity
fi

eval "$(tr '\0' '\n' < /proc/${$}/environ | grep '^DISPLAY=')"

env XENVIRONMENT="${HOME}/.config/mash/app/Xresources" \
    URXVT_PERL_LIB="${HOME}/.config/mash/app/extensions" \
    PERL5LIB="${HOME}/.config/mash/urxvt" \
    DISPLAY="${DISPLAY}" \
    "${HOME}/.config/mash/bin/rxvt" \
    -icon "${ICONDIR}/hicolor/22x22/apps/mash.png" \
    -name "mash" -e bash -c "stty -ixon susp undef; \
        ${HOME}/.config/mash/bin/vim --servername mash-${$} \
        -u ${HOME}/.config/mash/app/init.vim ${*}"
