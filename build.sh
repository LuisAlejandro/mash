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

function echospaced() {
    printf "\n# %s\n" "${1}"
}

BASEDIR="$(pwd)"
BUILDDIR="${BASEDIR}/build"
VERSION="0.1.0a2"

ICONSIZES="16 22 32 48 64 128 256 512"

BUILDER="luis@collagelabs.org"
FONTNAME="DejaVu Sans Mono for Powerline Nerd Font Complete Mono.ttf"
ESCFONTNAME="$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${FONTNAME}'''))")"

DEB_BUILD_MAINT_OPTIONS="hardening=+all,-fortify"
DEB_HOST_GNU_TYPE="$(dpkg-architecture -qDEB_HOST_GNU_TYPE)"
DEB_BUILD_GNU_TYPE="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)"
CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS) -Wall"
CFLAGS="$(dpkg-buildflags --get CFLAGS) -Wall"
CXXFLAGS="$(dpkg-buildflags --get CXXFLAGS) -Wall"
LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"

VIM_FLAGS=" \
    CPPFLAGS=\"${CPPFLAGS}\" \
    CFLAGS=\"${CFLAGS}\" \
    CXXFLAGS=\"${CXXFLAGS}\" \
    LDFLAGS=\"${LDFLAGS}\""

VIM_CONFIG=" \
    --prefix=/opt \
    --mandir=\${prefix}/share/man \
    --without-local-dir \
    --with-modified-by=${BUILDER} \
    --with-compiledby=${BUILDER} \
    --enable-fail-if-missing \
    --with-global-runtime=\$VIMRUNTIME \
    --enable-cscope \
    --enable-canberra \
    --enable-gpm \
    --enable-selinux \
    --disable-smack \
    --with-features=huge \
    --enable-acl \
    --enable-terminal \

    --with-x \
    --enable-xim \

    --enable-gui=gtk3 \
    --enable-gtk3-check \
    --disable-gnome-check \
    --disable-motif-check \
    --disable-athena-check \
    --disable-fontset \

    --enable-luainterp \
    --disable-mzschemeinterp \
    --enable-perlinterp \
    --enable-python3interp \
    --with-python3-config-dir=$(python3-config --configdir) \
    --disable-pythoninterp \
    --enable-rubyinterp \
    --enable-tclinterp \
    --with-tclsh=/usr/bin/tclsh"

URXVT_FLAGS=" \
    CPPFLAGS=\"${CPPFLAGS}\" \
    CFLAGS=\"${CFLAGS}\" \
    CXXFLAGS=\"${CXXFLAGS}\" \
    LDFLAGS=\"${LDFLAGS}\""

URXVT_CONFIG=" \
    --host=${DEB_HOST_GNU_TYPE} \
    --build=${DEB_BUILD_GNU_TYPE} \
    --prefix=/opt \
    --mandir=\${prefix}/share/man \
    --infodir=\${prefix}/share/info \
    --enable-keepscrolling \
    --enable-selectionscrolling \
    --enable-pointer-blank \
    --enable-utmp \
    --enable-wtmp \
    --enable-warnings \
    --enable-lastlog \
    --enable-unicode3 \
    --enable-combining \
    --enable-xft \
    --enable-font-styles \
    --enable-256-color \
    --enable-24-bit-color \
    --enable-pixbuf \
    --enable-transparency \
    --enable-fading \
    --enable-rxvt-scroll \
    --enable-next-scroll \
    --enable-xterm-scroll \
    --enable-perl \
    --enable-xim \
    --enable-iso14755 \
    --enable-mousewheel \
    --enable-slipwheeling \
    --enable-smart-resize \
    --enable-startup-notification \
    --with-term=rxvt-unicode-256color"

PLUGINLIST=" \
    https://github.com/CollageLabs/vim-autoswap/archive/aa516a72ff06802470b12b9d3ba8940a833bc68f.zip \
    https://github.com/xolox/vim-misc/archive/3e6b8fb6f03f13434543ce1f5d24f6a5d3f34f0b.zip \
    https://github.com/xolox/vim-easytags/archive/72a8753b5d0a951e547c51b13633f680a95b5483.zip \
    https://github.com/kristijanhusak/vim-multiple-cursors/archive/a95edcdffd98c5961f067796fbc2a1a82e0f6a83.zip \
    https://github.com/junegunn/goyo.vim/archive/5b8bd0378758c1d9550d8429bef24b3d6d78b592.zip \
    https://github.com/dkprice/vim-easygrep/archive/d0c36a77cc63c22648e792796b1815b44164653a.zip \
    https://github.com/Shougo/unite.vim/archive/ada33d888934d8a9e60aa8ff828b651aaedb6457.zip \
    https://github.com/Shougo/neocomplete.vim/archive/4fd73faa262f5e3063422d9fc244c65f1b758cf3.zip \
    https://github.com/Shougo/neosnippet.vim/archive/9996520d6bf1aaee21f66b5eb561c9f0b306216c.zip \
    https://github.com/Shougo/neosnippet-snippets/archive/2a9487bacb924d8e870612b6b0a2afb34deea0ae.zip \
    https://github.com/airblade/vim-gitgutter/archive/b803a28f47b26d16f5fe9e747850992c9985c667.zip \
    https://github.com/tomtom/tcomment_vim/archive/3.08.zip \
    https://github.com/jiangmiao/auto-pairs/archive/v1.3.3.zip \
    https://github.com/vim-syntastic/syntastic/archive/3.8.0.zip \
    https://github.com/sheerun/vim-polyglot/archive/v2.17.0.zip \
    https://github.com/Shougo/vimproc.vim/archive/ver.9.2.zip \
    https://github.com/preservim/nerdtree/archive/5.1.0.zip \
    https://github.com/vim-airline/vim-airline/archive/v0.8.zip \
    https://github.com/tpope/vim-fugitive/archive/v2.2.zip \
    https://github.com/ryanoasis/vim-devicons/archive/v0.9.2.zip"

mkdir -vp "${BUILDDIR}/vim"
mkdir -vp "${BUILDDIR}/urxvt"
mkdir -vp "${BUILDDIR}/ui"
mkdir -vp "${BUILDDIR}/plugins"
mkdir -vp "${BUILDDIR}/fonts"
mkdir -vp "${BUILDDIR}/plug"

echospaced "Downloading Vim source ..."
git clone --depth 1 --branch v8.2.0716 --single-branch \
    --recursive --shallow-submodules \
    https://github.com/vim/vim "${BUILDDIR}/vim"

echospaced "Downloading Urxvt source ..."
git clone --depth 1 --branch 24bit-deprecated --single-branch \
    --recursive --shallow-submodules \
    https://github.com/CollageLabs/rxvt-unicode "${BUILDDIR}/urxvt"

echospaced "Downloading Mash fonts ..."
curl -fLo "${BUILDDIR}/fonts/${FONTNAME}" --create-dirs \
    "https://github.com/CollageLabs/nerd-fonts/raw/v1.0.0/patched-fonts/DejaVuSansMono/Regular/complete/${ESCFONTNAME}"

echospaced "Downloading Mash plugin manager ..."
curl -fLo "${BUILDDIR}/plug/autoload/plug.vim" --create-dirs \
    https://github.com/CollageLabs/vim-plug/raw/0.9.1/plug.vim

echospaced "Downloading Mash plugins ..."
cd "${BUILDDIR}/plugins"
for ZIPBALL in ${PLUGINLIST}; do
    REPONAME="$(echo ${ZIPBALL} | awk -F'/' '{print $5}')"
    FILENAME="$(basename ${ZIPBALL})"
    curl -OL ${ZIPBALL}
    unzip ${FILENAME}
    mv "${REPONAME}-"* "${REPONAME}"
    rm ${FILENAME}
done

echospaced "Compiling vimproc ..."
cd "${BUILDDIR}/plugins/vimproc.vim" && make

echospaced "Compiling Vim ..."
cp -vf "${BUILDDIR}/vim/src/config.mk.dist" "${BUILDDIR}/vim/src/auto/config.mk"
echo "255 165   0		Orange" >> "${BUILDDIR}/vim/runtime/rgb.txt"
cd "${BUILDDIR}/vim"
env "${VIM_FLAGS}" ./configure ${VIM_CONFIG} && make

echospaced "Compiling Urxvt ..."
cd "${BUILDDIR}/urxvt"
env "${URXVT_FLAGS}" ./configure ${URXVT_CONFIG} && make

echospaced "Compiling Mash UI ..."
cp -vf "${BASEDIR}/ui/search.c" "${BASEDIR}/ui/search.css" "${BUILDDIR}/ui"
cd "${BUILDDIR}/ui"
gcc $(pkg-config --cflags gtk+-3.0) "search.c" -o "search" $(pkg-config --libs gtk+-3.0)

echospaced "Generating Mash icons ..."
for SIZE in ${ICONSIZES}; do
    mkdir -p "${BUILDDIR}/icons/hicolor/${SIZE}x${SIZE}/apps"
    convert -verbose -background None -resize "${SIZE}x${SIZE}" \
        "${BASEDIR}/mash.svg" \
        "${BUILDDIR}/icons/hicolor/${SIZE}x${SIZE}/apps/collagelabs-mash.png"
done
