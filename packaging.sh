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

PKGNAME="$(dpkg-parsechangelog | grep-dctrl -esSource . | awk -F' ' '{print $2}')"
VERSION="${1}"
ORIGVER=$(echo ${VERSION} | sed 's/-.*//g' )

gbp dch --new-version="${VERSION}" --release --auto --id-length=7 --full --commit --git-author

tar --anchored --exclude-vcs --exclude "./debian" --exclude "./build" -cvzf ../$( echo ${PKGNAME}"_"${ORIGVER} ).orig.tar.gz --directory="$(pwd)" ./
gbp buildpackage -tc -us -uc -nc -F

gbp buildpackage --git-sign-tags --git-keyid="luis@collagelabs.org" \
    --git-ignore-new --git-force-create --git-no-pristine-tar \
    --git-upstream-branch=develop --git-debian-branch=develop \
    --git-upstream-tree=SLOPPY  --git-export=WC
