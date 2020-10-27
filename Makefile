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

SHELL = sh -e

image:

	@docker build --rm -t collagelabs/mash:latest .

console:

	@docker run -it -w $(shell pwd) \
		-v $(shell pwd | xargs dirname):$(shell pwd | xargs dirname) \
		collagelabs/mash:latest bash

build: clean

	@bash build.sh

install:

	@mkdir -p $(DESTDIR)/usr/bin
	@mkdir -p $(DESTDIR)/usr/share/mash/app
	@mkdir -p $(DESTDIR)/usr/share/mash/bin
	@mkdir -p $(DESTDIR)/usr/share/mash/urxvt

	@cp -rf build/ui/search $(DESTDIR)/usr/share/mash/bin
	@cp -rf build/ui/search.css $(DESTDIR)/usr/share/mash/bin
	@cp -rf build/urxvt/src/rxvt $(DESTDIR)/usr/share/mash/bin
	@cp -rf build/vim/src/vim $(DESTDIR)/usr/share/mash/bin

	@cp -rf build/urxvt/src/urxvt.pm $(DESTDIR)/usr/share/mash/urxvt
	@cp -rf build/vim/runtime $(DESTDIR)/usr/share/mash
	@cp -rf build/plugins $(DESTDIR)/usr/share/mash
	@cp -rf build/plug $(DESTDIR)/usr/share/mash
	@cp -rf build/fonts $(DESTDIR)/usr/share/mash
	@cp -rf build/icons $(DESTDIR)/usr/share/mash
	@rsync -a --exclude "$(shell pwd)/build/*" $(shell pwd)/ $(DESTDIR)/usr/share/mash/app

	@cp -rf mash.sh $(DESTDIR)/usr/bin/mash
	@chmod +x $(DESTDIR)/usr/bin/mash

uninstall:

	@rm -rf /usr/bin/mash /usr/share/mash

clean:

	@rm -rf ./build ./debian/mash

.PHONY: build image console install clean