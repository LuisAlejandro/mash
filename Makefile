#!/usr/bin/make -f
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

image:

	@docker build --rm -t collagelabs/mash:latest .

console:

	@docker run -it -w ${PWD} -v ${PWD}:${PWD} collagelabs/mash:latest bash

build: clean

	@bash build.sh

install:

	@mkdir -vp $(DESTDIR)/usr/bin
	@mkdir -vp $(DESTDIR)/usr/share/mash/bin
	@mkdir -vp $(DESTDIR)/usr/share/mash/urxvt

	@cp -vrf build/ui/search $(DESTDIR)/usr/share/mash/bin
	@cp -vrf build/urxvt/src/rxvt $(DESTDIR)/usr/share/mash/bin
	@cp -vrf build/vim/src/vim $(DESTDIR)/usr/share/mash/bin

	@cp -vrf build/urxvt/src/urxvt.pm $(DESTDIR)/usr/share/mash/urxvt
	@cp -vrf build/vim/runtime $(DESTDIR)/usr/share/mash
	@cp -vrf build/plugins $(DESTDIR)/usr/share/mash
	@cp -vrf build/plug $(DESTDIR)/usr/share/mash
	@cp -vrf build/fonts $(DESTDIR)/usr/share/mash
	@cp -vrf build/icons $(DESTDIR)/usr/share/mash
	@cp -vrf build/app $(DESTDIR)/usr/share/mash
	@cp -vrf metadata.conf $(DESTDIR)/usr/share/mash
	@cp -vrf collagelabs-mash.desktop $(DESTDIR)/usr/share/mash

	@cp -vrf mash.sh $(DESTDIR)/usr/bin/mash
	@chmod +x $(DESTDIR)/usr/bin/mash

clean:

	@rm -rf ./build ./debian/mash

.PHONY: build image console install clean