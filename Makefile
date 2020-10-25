#!/usr/bin/make -f

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