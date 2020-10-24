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
FONTNAME="DejaVu Sans Mono Nerd Font Complete Mono.ttf"


echospaced "Removing icons ..."
for S in ${ICONSIZES}; do
	xdg-icon-resource uninstall --size "${S}" --theme "hicolor" \
		--context "apps" --mode "user" mash
done

echospaced "Removing desktop and menu files ..."
xdg-desktop-icon uninstall "${HOME}/.config/mash/app/mash.desktop"
xdg-desktop-menu uninstall "${HOME}/.config/mash/app/mash.desktop"

echospaced "Removing folders ..."
rm -rfv "${HOME}/.config/mash"*
rm -rfv "${HOME}/.local/share/fonts/${FONTNAME}"
rm -rfv "${HOME}/.local/bin/mash"

echospaced "Updating font cache ..."
fc-cache -vr "${HOME}/.local/share/fonts"

echospaced "Deconfiguring executables ..."
if [ -f "${HOME}/.bashrc" ]; then
	if grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
		sed -i 's|PATH="${PATH}:${HOME}/.local/bin"||g' "${HOME}/.bashrc"
	fi
fi