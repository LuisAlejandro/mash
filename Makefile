#!/usr/bin/make -f
# -*- makefile -*-

APTGET=$(shell which apt-get )
APTGETCMD=env DEBIAN_FRONTEND=noninteractive ${APTGET}
APTGETOPTS=-qq -o Apt::Install-Recommends=false \
	-o Apt::Get::Assume-Yes=true \
	-o Apt::Get::AllowUnauthenticated=true \
	-o DPkg::Options::=--force-confmiss \
	-o DPkg::Options::=--force-confnew \
	-o DPkg::Options::=--force-overwrite \
	-o DPkg::Options::=--force-unsafe-io
TRMFONTNAME=Droid Sans Mono for Powerline 11
TRMPROFILEID=$(shell dconf list /org/gnome/terminal/legacy/profiles:/ | sed -n '1p' | sed 's|/||g')

BUILDPKGLIST=cmake golang npm libboost-python-dev libboost-filesystem-dev \
			 libboost-thread-dev libboost-regex-dev libclang-dev
RUNPKGLIST=silversearcher-ag exuberant-ctags vim-nox xsel rsync
LINTPKGLIST=golang npm clang-tidy ruby virtualenv npm php-cli cabal-install

RUBYSNDBX=${HOME}/.subliminal-vim/sandboxes/ruby
PYTHONSNDBX=${HOME}/.subliminal-vim/sandboxes/python
NODESNDBX=${HOME}/.subliminal-vim/sandboxes/node
GOSNDBX=${HOME}/.subliminal-vim/sandboxes/go
HASKELLSNDBX=${HOME}/.subliminal-vim/sandboxes/haskell
PERLSNDBX=${HOME}/.subliminal-vim/sandboxes/perl

NODEPKGLIST=textlint-plugin-html textlint jshint jscs \
			textlint-plugin-markdown csslint dockerfile_lint jsonlint
PYTHONPKGLIST=vim-vint pylint pyflakes pep8 pydocstyle
GOPKGLIST=github.com/alecthomas/gometalinter
RUBYPKGLIST=sqlint rubocop
HASKELLPKGLIST=shellcheck

CHECKBASHISMSBINURL=https://anonscm.debian.org/cgit/collab-maint/devscripts.git/plain/scripts/checkbashisms.pl

all: init install_build_dependencies build
install: copy install_runtime_dependencies install_linters config

init:

	@git submodule update --init --recursive
	@git submodule foreach --recursive git clean -xfd

install_build_dependencies:

	@sudo ${APTGETCMD} ${APTGETOPTS} update
	@sudo ${APTGETCMD} ${APTGETOPTS} install ${BUILDPKGLIST}

build:

	@cd bundle/YouCompleteMe && python install.py \
		--clang-completer --gocode-completer \
		--tern-completer --system-libclang --system-boost
	@convert -background None subliminal-vim.svg subliminal-vim.png

copy:

	@if [ -f ${HOME}/.subliminal-vim ]; then \
		rm -rf ${HOME}/.subliminal-vim.bak; \
		mv ${HOME}/.subliminal-vim ${HOME}/.subliminal-vim.bak; \
	fi
	@mkdir -p ${HOME}/.subliminal-vim/bundle
	@mkdir -p ${HOME}/.subliminal-vim/tempdir
	@mkdir -p ${HOME}/.local/share/fonts
	@rsync -qavz *.vim ${HOME}/.subliminal-vim/
	@rsync -qavz bundle/* ${HOME}/.subliminal-vim/bundle/
	@rsync -qavz fonts/* ${HOME}/.local/share/fonts/
	@rsync -qavz Xresources subliminal-vim.png subliminal-vim.desktop subliminal-vim.sh ${HOME}/.subliminal-vim/
	@sudo ln -fs ${HOME}/.subliminal-vim/subliminal-vim.desktop /usr/share/applications/
	@sudo ln -fs ${HOME}/.subliminal-vim/subliminal-vim.sh /usr/bin/subliminal-vim
	@sudo ln -fs ${HOME}/.subliminal-vim/subliminal-vim.png /usr/share/icons/

install_runtime_dependencies:

	@sudo ${APTGETCMD} ${APTGETOPTS} update
	@sudo ${APTGETCMD} ${APTGETOPTS} install ${RUNPKGLIST}

install_linters:

	@sudo ${APTGETCMD} ${APTGETOPTS} update
	@sudo ${APTGETCMD} ${APTGETOPTS} install ${LINTPKGLIST}
	@mkdir -p ${PERLSNDBX}/bin \
		&& wget --no-check-certificate -O ${PERLSNDBX}/bin/checkbashisms ${CHECKBASHISMSBINURL}
	@gem install --install-dir ${RUBYSNDBX} ${RUBYPKGLIST}
	@virtualenv ${PYTHONSNDBX} \
		&& ${PYTHONSNDBX}/bin/pip install ${PYTHONPKGLIST}
	@mkdir -p ${NODESNDBX} \
		&& npm --prefix ${NODESNDBX} install ${NODEPKGLIST}
	@export GOPATH=${GOSNDBX} \
		&& go get ${GOPKGLIST} \
		&& ${GOSNDBX}/bin/gometalinter -i -u
	@cabal install --prefix ${HASKELLSNDBX} ${HASKELLPKGLIST}

config:

	@fc-cache -rfv ${HOME}/.local/share/fonts
	@echo "stty -ixon" >> ${HOME}/.bashrc
	@dconf write /org/gnome/terminal/legacy/profiles:/${TRMPROFILEID}/font "'${TRMFONTNAME}'"
	@dconf write /org/gnome/terminal/legacy/profiles:/${TRMPROFILEID}/use-system-font "false"
	@bash
