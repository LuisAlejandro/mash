# Deprecation notice

This repository is now archived. I lost interest in keeping up with the development of this product.



<img align="right" height="100" src="https://cloud.githubusercontent.com/assets/324683/14374725/0a483732-fd23-11e5-9b56-b0e280b20760.png">

# Mash

> An open source alternative to Sublime Text based on vim and urxvt

Current version: 0.1.0a2

**Attention: this in an alpha release. Don't use it on production environments as
you will probably experience bugs.**

*Mash* is a group of Vim plugins and configurations designed to resemble
the appeareance and functionality of Sublime Text. Its main purpose is to make
users from Sublime to be more comfortable using Vim and perhaps encourage them
to switch IDE environments in the future.

*Mash* needs a graphical interface to work because we need urxvt for
proper key shorcuts, but in the future this might change. This means it won't
work on server environments, sorry. *Mash* ships as a separate binary
and does not integrate with Vim (yet). See [Usage](#usage) for details.

Also, for now we are only supporting Debian-based systems on the installation
script, but you might want to try installing on a different OS and tell us how
you you did it, or submit a
[greatly appreciated PR](https://github.com/CollageLabs/mash/pulls).

![Screenshot](https://cloud.githubusercontent.com/assets/324683/18112460/b9c94b3a-6ef5-11e6-9d11-43df8c950f87.png "Screenshot")

## Features

* Sublime Text key shorcuts and functionality. 
* Syntax highlighting of popular languages.
* Integrated linting and autocomplete for Python, Perl, Ruby, Javascript, Go, Haskell & more.

## Known bugs - work in progess

* See the [issues section](https://github.com/CollageLabs/mash/issues)
for more information.

## Installation

First make sure that you have `sudo` and `curl` installed. If not, you can install it by opening
a root terminal and typing the following command:

```bash
apt-get install sudo curl
```

Then, open a user terminal and start the installation process with the following command.
This will take a few minutes to complete depending on your internet connection speed.

```bash
bash <(curl -fLo- https://raw.githubusercontent.com/CollageLabs/mash/develop/install.sh)
```

## Usage

You can click on Subliminal Vim's icon on the menu or execute it on console by
typing `mash`.

You can use the mouse to select documents on the panel, single click opens them.
You cannot select tabs by clicking on them (yet), you'll have to use key shorcuts
for that (Alt+1, Alt+2, ...).

### Common key shortcuts

| Shortcut | Function |
| --- | --- |
| `Ctrl-o` | Open document |
| `Ctrl-s` | Save document |
| `Ctrl-c` | Copy a block or single line of code |
| `Ctrl-x` | Cut a block or single line of code |
| `Ctrl-v` | Paste a block or single line of code |
| `Ctrl-z` | Undo last action |
| `Ctrl-y` | Redo last action |
| `Ctrl-w` | Close current file |
| `Ctrl-Shift-7` | Comment a block or single line of code |
| `Ctrl-Shift-Up` | Move a block or single line up |
| `Ctrl-Shift-Down` | Move a block or single line down |

## License

Copyright (C) 2016 Mash Developers

Please refer to CONTRIBUTORS.md for a complete list of Copyright holders.

Mash is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

Mash is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see http://www.gnu.org/licenses/.

<!-- 

DEBIANSNDBX="${HOME}/.config/mash/sandboxes/debian"
RUBYSNDBX="${HOME}/.config/mash/sandboxes/ruby"
PYTHONSNDBX="${HOME}/.config/mash/sandboxes/python"
NODESNDBX="${HOME}/.config/mash/sandboxes/node"
GOSNDBX="${HOME}/.config/mash/sandboxes/go"

PYTHONPKGLIST="pylint pyflakes pep8 pydocstyle docutils yamllint vim-vint"
NODEPKGLIST="jshint jsonlint csslint sass-lint less dockerfile_lint"
RUBYPKGLIST="rubocop mdl sqlint"
GOPKGLIST="github.com/golang/lint/golint"

BUILDPKGLIST="
make,
imagemagick,
librsvg2-bin,
silversearcher-ag,
exuberant-ctags,
xclip,
wmctrl,
fontconfig,
git,
zenity,
curl,
bash,
gksu,
xdg-utils,
coreutils"

INSTALL_ARGS_FILE="${HOME}/.config/mash/install-args.conf"

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

} | tee ${TEMPFILE} -->
