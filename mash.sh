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

eval "$(tr '\0' '\n' < /proc/${$}/environ | grep '^DISPLAY=')"

TEMPFILE="$(mktemp -u)"
SHAREDIR="/usr/share/mash"
ICONSIZES="16 22 32 48 64 128 256 512"
FONTNAME="DejaVu Sans Mono Nerd Font Complete Mono.ttf"

# DEBIANSNDBX="${HOME}/.config/mash/sandboxes/debian"
# RUBYSNDBX="${HOME}/.config/mash/sandboxes/ruby"
# PYTHONSNDBX="${HOME}/.config/mash/sandboxes/python"
# NODESNDBX="${HOME}/.config/mash/sandboxes/node"
# GOSNDBX="${HOME}/.config/mash/sandboxes/go"

# PYTHONPKGLIST="pylint pyflakes pep8 pydocstyle docutils yamllint vim-vint"
# NODEPKGLIST="jshint jsonlint csslint sass-lint less dockerfile_lint"
# RUBYPKGLIST="rubocop mdl sqlint"
# GOPKGLIST="github.com/golang/lint/golint"

# BUILDPKGLIST="
# make,
# imagemagick,
# librsvg2-bin,
# silversearcher-ag,
# exuberant-ctags,
# xclip,
# wmctrl,
# fontconfig,
# git,
# zenity,
# curl,
# bash,
# gksu,
# xdg-utils,
# coreutils"

INSTALL_ARGS_FILE="${HOME}/.config/mash/install-args.conf"

if [ ! -d "${HOME}/.config/mash" ]; then

    echospaced "Creating folders ..."
    mkdir -vp "${HOME}/.local/bin"
    mkdir -vp "${HOME}/.config/mash/recovery"
    mkdir -vp "${HOME}/.config/mash/backups"
    mkdir -vp "${HOME}/.config/mash/undo"

    echospaced "Copying files ..."
    cp -rf "${SHAREDIR}/bin/." "${HOME}/.config/mash/bin"
    cp -rf "${SHAREDIR}/plugins/mash/." "${HOME}/.config/mash/app"
    cp -rf "${SHAREDIR}/urxvt" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/runtime" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/plug" "${HOME}/.config/mash"
    cp -rf "${SHAREDIR}/mash.sh" "${HOME}/.local/bin/mash"
    chmod +x "${HOME}/.local/bin/mash"

    echospaced "Installing icons ..."
    for SIZE in ${ICONSIZES}; do
        xdg-icon-resource install --size "${SIZE}" \
            "${SHAREDIR}/icons/hicolor/${SIZE}x${SIZE}/apps/mash.png" \
            mash
    done

    echospaced "Installing desktop and menu files ..."
    xdg-desktop-icon install "${SHAREDIR}/mash.desktop"
    xdg-desktop-menu install "${SHAREDIR}/mash.desktop"

    echospaced "Updating font cache ..."
    cp -vf "${SHAREDIR}/fonts/${FONTNAME}" "${HOME}/.local/share/fonts/"
    fc-cache -vr "${HOME}/.local/share/fonts"

    echospaced "Configuring executables ..."
    if [ ! -f "${HOME}/.bashrc" ]; then
        touch "${HOME}/.bashrc"
    fi

    if ! grep -q 'PATH="${PATH}:${HOME}/.local/bin"' "${HOME}/.bashrc"; then
        echo 'PATH="${PATH}:${HOME}/.local/bin"' >> "${HOME}/.bashrc"
    fi
fi

if [ ! -f "${INSTALL_ARGS_FILE}" ]; then

    INSTALLDESC="Mash ships with linting, syntax highlighting and \
completion support. Please select below which ones would you like to activate."

    ANS="$( zenity --list --text "${INSTALLDESC}" --checklist --separator "\n" \
        --height 500 --width 800 --hide-column 4 --print-column 4 --window-icon "${WINDOW_ICON}" \
        --column "Select" --column "Language" --column "Description" --column "O" \
        TRUE "Python" "Uses pep8, pylint, pyflakes and pydocstyle as linters, and neocomplete for completion." include-python \
        TRUE "Ruby" "Uses rubocop and ruby as linters and neocomplete for completion." include-ruby \
        TRUE "Shell/Bash" "Uses sh, checkbashisms and shellcheck as linters." include-shell \
        TRUE "Javascript and JSON" "Uses jshint as linter." include-js \
        TRUE "HTML, XHTML and XML" "Uses tidy and xmllint as linters." include-html \
        TRUE "YAML" "Uses yamllint as linter." include-yaml \
        TRUE "PO" "Uses gettext as linter." include-po \
        TRUE "CSS, SASS, SCSS and LESS" "Uses csslint, less and sass-lint as linters." include-css \
        TRUE "Markdown and RST" "Uses textlint and docutils as linters." include-markdown \
        TRUE "Dockerfile" "Uses dockerfile_lint as linter." include-docker \
        TRUE "Go" "Uses go, gofmt and golint as linters." include-go \
        TRUE "Vim" "Uses vint as a linter." include-vim \
        FALSE "C, C++, Obj-C and Obj-C++" "Uses GCC to find syntax errors." include-c \
        FALSE "C#" "Uses mono to find syntax errors." include-csharp \
        FALSE "SQL" "Uses sqlint as linter." include-sql \
        FALSE "PHP" "Uses php (cli) to find syntax errors." include-php \
        FALSE "Rust" "Uses rustc as linter." include-rust 2>/dev/null )"

    if [ ${?} -eq 1 ]; then
        exit 0
    fi

    if [ -n "${ANS}" ]; then
        printf -- '--%s\n' "${ANS}" > "${INSTALL_ARGS_FILE}"
    else
        touch "${INSTALL_ARGS_FILE}"
    fi
fi

INSTALL_ARGS="$( cat "${INSTALL_ARGS_FILE}" )"

for OPT in ${INSTALL_ARGS}; do
    case ${OPT} in
        --include-python)
            BUILDPKGLIST="virtualenv python-dev ${BUILDPKGLIST}"
            RUNPKGLIST="python ${RUNPKGLIST}"
        ;;

        --include-shell)
            RUNPKGLIST="bash devscripts shellcheck ${RUNPKGLIST}"
        ;;

        --include-js)
            RUNPKGLIST="nodejs ${RUNPKGLIST}"
        ;;

        --include-ruby)
            BUILDPKGLIST="ruby-dev ${BUILDPKGLIST}"
            RUNPKGLIST="ruby ${RUNPKGLIST}"
        ;;

        --include-go)
            RUNPKGLIST="golang-go ${RUNPKGLIST}"
        ;;

        --include-markdown)
            BUILDPKGLIST="virtualenv python-dev ruby-dev ${BUILDPKGLIST}"
            RUNPKGLIST="python ruby ${RUNPKGLIST}"
        ;;

        --include-po)
            RUNPKGLIST="gettext ${RUNPKGLIST}"
        ;;

        --include-html)
            RUNPKGLIST="tidy libxml2-utils ${RUNPKGLIST}"
        ;;

        --include-yaml)
            BUILDPKGLIST="virtualenv python-dev ${BUILDPKGLIST}"
            RUNPKGLIST="python ${RUNPKGLIST}"
        ;;

        --include-css)
            RUNPKGLIST="nodejs ${RUNPKGLIST}"
        ;;

        --include-c)
            RUNPKGLIST="gcc ${RUNPKGLIST}"
        ;;

        --include-csharp)
            RUNPKGLIST="mono-devel ${RUNPKGLIST}"
        ;;

        --include-vim)
            BUILDPKGLIST="virtualenv python-dev ${BUILDPKGLIST}"
            RUNPKGLIST="python ${RUNPKGLIST}"
        ;;

        --include-sql)
            BUILDPKGLIST="ruby-dev ${BUILDPKGLIST}"
            RUNPKGLIST="ruby ${RUNPKGLIST}"
        ;;

        --include-php)
            RUNPKGLIST="php5-cli ${RUNPKGLIST}"
        ;;

        --include-docker)
            RUNPKGLIST="nodejs ${RUNPKGLIST}"
        ;;

        --include-rust)
            RUNPKGLIST="rustc ${RUNPKGLIST}"
        ;;
    esac
done

if [ -n "$(which dpkg)" ]; then
    APTGETCMD="apt-get"
    APTGETOPTS="-o Apt::Install-Recommends=false \
        -o Apt::Get::Assume-Yes=true \
        -o Apt::Get::AllowUnauthenticated=true \
        -o DPkg::Options::=--force-confmiss \
        -o DPkg::Options::=--force-confnew \
        -o DPkg::Options::=--force-overwrite \
        -o DPkg::Options::=--force-unsafe-io"

    for DDEP in ${BUILDPKGLIST} ${RUNPKGLIST}; do
        if ! dpkg -L "${DDEP}" >/dev/null 2>&1; then
            DDEPENDS="${DDEP} ${DDEPENDS}"
        fi
    done
fi

for RDEP in ${RUBYPKGLIST}; do
    if [ ! -f "${BASEDIR}/sandboxes/ruby/bin/${RDEP}" ]; then
        RDEPENDS="${RDEP} ${RDEPENDS}"
    fi
done

for PDEP in ${PYTHONPKGLIST}; do
    REALBIN="${PDEP}"
    if [ "${PDEP}" == "docutils" ]; then
        REALBIN="rst2pseudoxml.py"
    fi
    if [ "${PDEP}" == "vim-vint" ]; then
        REALBIN="vint"
    fi
    if [ ! -f "${BASEDIR}/sandboxes/python/bin/${REALBIN}" ]; then
        PDEPENDS="${PDEP} ${PDEPENDS}"
    fi
done

for NDEP in ${NODEPKGLIST}; do
    REALBIN="${NDEP}"
    if [ "${NDEP}" == "less" ]; then
        REALBIN="lessc"
    fi
    if [ ! -f "${BASEDIR}/sandboxes/node/node_modules/.bin/${REALBIN}" ]; then
        NDEPENDS="${NDEP} ${NDEPENDS}"
    fi
done

for GDEP in ${GOPKGLIST}; do
    REALBIN="${GDEP}"
    if [ "${GDEP}" == "github.com/golang/lint/golint" ]; then
        REALBIN="golint"
    fi
    if [ ! -f "${BASEDIR}/sandboxes/go/bin/${REALBIN}" ]; then
        GDEPENDS="${GDEP} ${GDEPENDS}"
    fi
done

mkfifo ${TEMPFILE}
zenity --progress --pulsate --auto-close --no-cancel \
    --window-icon "${WINDOW_ICON}" --height 100 \
    --width 600 < ${TEMPFILE} 2>/dev/null &

{
    if [ -n "${DDEPENDS}" ]; then
        echospaced "Installing missing dpkg dependencies ..."
        docker run -it -w ${PWD} -v ${PWD}:${PWD} collagelabs/mash:build fakechroot fakeroot chroot ${DEBIANSNDBX} ${APTGETCMD} ${APTGETOPTS} update
        docker run -it -w ${PWD} -v ${PWD}:${PWD} collagelabs/mash:build fakechroot fakeroot chroot ${DEBIANSNDBX} ${APTGETCMD} ${APTGETOPTS} install ${DDEPENDS}
    fi

    exit 0

    if [ -n "${RDEPENDS}" ]; then
        echospaced "Installing missing ruby dependencies ..."
        ${DEBIANSNDBX}/usr/local/gem install --install-dir "${RUBYSNDBX}" ${RUBYPKGLIST}
    fi

    if [ -n "${PDEPENDS}" ]; then
        echospaced "Installing missing python dependencies ..."
        ${PYTHONSNDBX}/bin/pip3 install ${PYTHONPKGLIST}
    fi

    if [ -n "${NDEPENDS}" ]; then
        echospaced "Installing missing nodejs dependencies ..."
        ${DEBIANSNDBX}/usr/local/npm --prefix "${NODESNDBX}" install ${NODEPKGLIST}
    fi

    if [ -n "${GDEPENDS}" ]; then
        echospaced "Installing missing go dependencies ..."
        env GOPATH="${GOSNDBX}" ${DEBIANSNDBX}/usr/local/go get -v ${GOPKGLIST}
    fi

} | tee ${TEMPFILE}

env XENVIRONMENT="${HOME}/.config/mash/app/Xresources" \
    URXVT_PERL_LIB="${HOME}/.config/mash/app/extensions" \
    PERL5LIB="${HOME}/.config/mash/urxvt" \
    DISPLAY="${DISPLAY}" \
    "${HOME}/.config/mash/bin/rxvt" \
    -icon "${HOME}/.local/share/icons/hicolor/22x22/apps/mash.png" \
    -name "mash" -e bash -c "stty -ixon susp undef; \
        ${HOME}/.config/mash/bin/vim --servername mash-${$} \
        -u ${HOME}/.config/mash/app/init.vim ${*}"
