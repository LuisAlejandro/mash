#!/usr/bin/env bash
#   This file is part of Mash
#   Copyright (c) 2016, Mash Developers
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


function echospaced() {
    printf "\n# %s\n" "${1}"
}

ICONSIZES="16 22 32 48 64 128 256 512"
FONTNAME="DejaVu Sans Mono for Powerline Nerd Font Complete Mono.ttf"

echospaced "Creating folders ..."
mkdir -vp "${HOME}/.config/mash/recovery"
mkdir -vp "${HOME}/.config/mash/backups"
mkdir -vp "${HOME}/.config/mash/undo"
mkdir -vp "${HOME}/.local/share/fonts"
mkdir -vp "${HOME}/.local/bin"

echospaced "Copying content ..."
cp -vf "${HOME}/.config/mash/app/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
cp -vf "${HOME}/.config/mash/app/mash.sh" "${HOME}/.local/bin/mash"

echospaced "Installing icons ..."
for S in ${ICONSIZES}; do
	convert -verbose -background None -resize "${S}x${S}" \
		"${HOME}/.config/mash/app/mash.svg" \
		"${HOME}/.config/mash/app/mash.png"
	xdg-icon-resource install --size "${S}" \
		"${HOME}/.config/mash/app/mash.png" \
		mash
	rm "${HOME}/.config/mash/app/mash.png"
done

echospaced "Installing desktop and menu files ..."
xdg-desktop-icon install "${HOME}/.config/mash/app/mash.desktop"
xdg-desktop-menu install "${HOME}/.config/mash/app/mash.desktop"

echospaced "Updating font cache ..."
fc-cache -vr "${HOME}/.local/share/fonts"

echospaced "Configuring executables ..."
if [ ! -f "${HOME}/.bashrc" ]; then
    touch "${HOME}/.bashrc"
fi

if ! grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
    echo 'PATH="${PATH}:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
fi
