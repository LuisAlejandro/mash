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
FONTNAME="DejaVu Sans Mono Nerd Font Complete Mono.ttf"


echospaced "Removing icons ..."
for S in ${ICONSIZES}; do
	xdg-icon-resource uninstall --size "${S}" --theme "hicolor" \
		--context "apps" --mode "user" subliminal-view
done

echospaced "Removing desktop and menu files ..."
xdg-desktop-icon uninstall "${HOME}/.config/subliminal-view/app/subliminal-view.desktop"
xdg-desktop-menu uninstall "${HOME}/.config/subliminal-view/app/subliminal-view.desktop"

echospaced "Removing folders ..."
rm -rfv "${HOME}/.config/subliminal-view"*
rm -rfv "${HOME}/.local/share/fonts/${FONTNAME}"
rm -rfv "${HOME}/.local/bin/subliminal-view"

echospaced "Updating font cache ..."
fc-cache -vr "${HOME}/.local/share/fonts"

echospaced "Deconfiguring executables ..."
if [ -f "${HOME}/.bashrc" ]; then
	if grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
		sed -i 's|PATH="${PATH}:${HOME}/.local/bin"||g' "${HOME}/.bashrc"
	fi
fi