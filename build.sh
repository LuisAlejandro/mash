#!/usr/bin/env bash

set -ex

function echospaced() {
    printf "\n# %s\n" "${1}"
}

BASEDIR="$(pwd)"
BUILDDIR="${BASEDIR}/build"

ICONSIZES="16 22 32 48 64 128 256 512"

BUILDER="luis@luisalejandro.org"
PLUGINREPOS="$(cat "${BASEDIR}/init.vim" | grep "Plug" | awk -F"'" '{print "https://github.com/"$2".git"}')"
NERDFONT="DejaVu Sans Mono Nerd Font Complete Mono.ttf"
ESCNERDFONT="$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${NERDFONT}'''))")"

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
    --enable-cscope \
    --with-features=huge \
    --enable-multibyte \
    --enable-acl \
    --enable-gpm \
    --enable-selinux \
    --disable-smack \
    --with-x \
    --enable-xim \
    --disable-gui \
    --enable-fontset \
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

mkdir -vp "${BUILDDIR}/vim"
mkdir -vp "${BUILDDIR}/urxvt"
mkdir -vp "${BUILDDIR}/ui"
mkdir -vp "${BUILDDIR}/plugins"
mkdir -vp "${BUILDDIR}/fonts"
mkdir -vp "${BUILDDIR}/plug"

echospaced "Downloading Vim source ..."
git clone --depth 1 --branch v8.0.1635 --single-branch \
    --recursive --shallow-submodules \
    https://github.com/CollageLabs/vim "${BUILDDIR}/vim"

echospaced "Downloading Urxvt source ..."
git clone --depth 1 --branch 24bit-deprecated --single-branch \
    --recursive --shallow-submodules \
    https://github.com/CollageLabs/rxvt-unicode "${BUILDDIR}/urxvt"

echospaced "Downloading Mash fonts ..."
curl -fLo "${BUILDDIR}/fonts/${NERDFONT}" --create-dirs \
    "https://github.com/CollageLabs/nerd-fonts/raw/v1.0.0/patched-fonts/DejaVuSansMono/Regular/complete/${ESCNERDFONT}"

curl -fLo "${BUILDDIR}/fonts/fontawesome-webfont.ttf" --create-dirs \
    https://github.com/CollageLabs/Font-Awesome/raw/v4.7.0/fonts/fontawesome-webfont.ttf

echospaced "Downloading Mash plugin manager ..."
curl -fLo "${BUILDDIR}/plug/autoload/plug.vim" --create-dirs \
    https://github.com/CollageLabs/vim-plug/raw/0.9.1/plug.vim

echospaced "Downloading Mash plugins ..."
for REPO in ${PLUGINREPOS}; do
    git clone --depth 1 --single-branch \
        ${REPO} "${BUILDDIR}/plugins/$(basename ${REPO::-4})"
done

echospaced "Compiling Vim ..."
cd "${BUILDDIR}/vim"
cp src/config.mk.dist src/auto/config.mk
env "${VIM_FLAGS}" ./configure ${VIM_CONFIG} && make

echospaced "Compiling Urxvt ..."
cd "${BUILDDIR}/urxvt"
env "${URXVT_FLAGS}" ./configure ${URXVT_CONFIG} && make

echospaced "Compiling Mash UI ..."
cp "${BASEDIR}/ui/search.c" "${BASEDIR}/ui/search.css" "${BUILDDIR}/ui"
cd "${BUILDDIR}/ui"
gcc $(pkg-config --cflags gtk+-3.0) "search.c" -o "search" $(pkg-config --libs gtk+-3.0)

echospaced "Generating Mash icons ..."
for SIZE in ${ICONSIZES}; do
    mkdir -p "${BUILDDIR}/icons/hicolor/${SIZE}x${SIZE}/apps"
    convert -verbose -background None -resize "${SIZE}x${SIZE}" \
        "${BASEDIR}/mash.svg" \
        "${BUILDDIR}/icons/hicolor/${SIZE}x${SIZE}/apps/mash.png"
done