#!/usr/bin/env bash
#   This file is part of Subliminal View
#   Copyright (c) 2016, Subliminal View Developers
#
#   Please refer to CONTRIBUTORS.md for a complete list of Copyright
#   holders.
#
#   Subliminal View is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   Subliminal View is distributed in the hope that it will be useful,
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
mkdir -vp "${HOME}/.config/subliminal-view/recovery"
mkdir -vp "${HOME}/.config/subliminal-view/backups"
mkdir -vp "${HOME}/.config/subliminal-view/undo"
mkdir -vp "${HOME}/.local/share/fonts"
mkdir -vp "${HOME}/.local/bin"

echospaced "Copying content ..."
cp -vf "${HOME}/.config/subliminal-view/app/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
cp -vf "${HOME}/.config/subliminal-view/app/subliminal-view.sh" "${HOME}/.local/bin/subliminal-view"

echospaced "Installing icons ..."
for S in ${ICONSIZES}; do
	convert -verbose -background None -resize "${S}x${S}" \
		"${HOME}/.config/subliminal-view/app/subliminal-view.svg" \
		"${HOME}/.config/subliminal-view/app/subliminal-view.png"
	xdg-icon-resource install --size "${S}" \
		"${HOME}/.config/subliminal-view/app/subliminal-view.png" \
		subliminal-view
	rm "${HOME}/.config/subliminal-view/app/subliminal-view.png"
done

echospaced "Installing desktop and menu files ..."
xdg-desktop-icon install "${HOME}/.config/subliminal-view/app/subliminal-view.desktop"
xdg-desktop-menu install "${HOME}/.config/subliminal-view/app/subliminal-view.desktop"

echospaced "Updating font cache ..."
fc-cache -vr "${HOME}/.local/share/fonts"

echospaced "Configuring executables ..."
if [ ! -f "${HOME}/.bashrc" ]; then
    touch "${HOME}/.bashrc"
fi

if ! grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
    echo 'PATH="${PATH}:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
fi
