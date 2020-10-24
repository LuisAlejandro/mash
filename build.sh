#!/usr/bin/env bash

set -ex

function echospaced() {
    printf "\n# %s\n" "${1}"
}

BASEDIR="$(pwd)"
URXVT_TEMPDIR="$(mktemp -d)"
VIM_TEMPDIR="$(mktemp -d)"

ICONSIZES="16 22 32 48 64 128 256 512"

BUILDER="luis@luisalejandro.org"
PLUGINREPOS="$(cat "${BASEDIR}/init.vim" | grep "Plug" | grep -v "mash" | awk -F"'" '{print "https://github.com/"$2".git"}')"
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

mkdir -vp "${BASEDIR}/mash/bin"
mkdir -vp "${BASEDIR}/mash/urxvt"
mkdir -vp "${BASEDIR}/mash/plugins"

echospaced "Downloading Vim source ..."
git clone --depth 1 --branch v8.0.1635 --single-branch \
    --recursive --shallow-submodules \
    https://github.com/CollageLabs/vim "${VIM_TEMPDIR}/vim"

echospaced "Downloading Urxvt source ..."
git clone --depth 1 --branch 24bit-deprecated --single-branch \
    --recursive --shallow-submodules \
    https://github.com/CollageLabs/rxvt-unicode "${URXVT_TEMPDIR}/urxvt"

echospaced "Compiling Vim ..."
cd "${VIM_TEMPDIR}/vim"
cp src/config.mk.dist src/auto/config.mk
env "${VIM_FLAGS}" ./configure ${VIM_CONFIG} && make

echospaced "Compiling Urxvt ..."
cd "${URXVT_TEMPDIR}/urxvt"
env "${URXVT_FLAGS}" ./configure ${URXVT_CONFIG} && make

echospaced "Compiling Mash UI ..."
cd "${BASEDIR}"
gcc $(pkg-config --cflags gtk+-3.0) "ui/search.c" -o "ui/search" $(pkg-config --libs gtk+-3.0)

echospaced "Copying Mash source ..."
cp -vrf "${BASEDIR}/mash.sh" "${BASEDIR}/mash/"
cp -vrf "${BASEDIR}/mash.desktop" "${BASEDIR}/mash/"
cp -vrf "${BASEDIR}/mash.svg" "${BASEDIR}/mash/"
cp -vrf "${BASEDIR}/ui/search" "${BASEDIR}/mash/bin"
cp -vrf "${URXVT_TEMPDIR}/urxvt/src/rxvt" "${BASEDIR}/mash/bin"
cp -vrf "${URXVT_TEMPDIR}/urxvt/src/urxvt.pm" "${BASEDIR}/mash/urxvt"
cp -vrf "${VIM_TEMPDIR}/vim/src/vim" "${BASEDIR}/mash/bin"
cp -vrf "${VIM_TEMPDIR}/vim/runtime" "${BASEDIR}/mash/"
chmod +x "${BASEDIR}/mash/mash.sh"

echospaced "Generating Mash icons ..."
for SIZE in ${ICONSIZES}; do
    mkdir -p "${BASEDIR}/mash/icons/hicolor/${SIZE}x${SIZE}/apps"
    convert -verbose -background None -resize "${SIZE}x${SIZE}" \
        "${BASEDIR}/mash.svg" \
        "${BASEDIR}/mash/icons/hicolor/${SIZE}x${SIZE}/apps/mash.png"
done

echospaced "Generating Mash fonts ..."
curl -fLo "${BASEDIR}/mash/fonts/${NERDFONT}" --create-dirs \
    "https://github.com/CollageLabs/nerd-fonts/raw/v1.0.0/patched-fonts/DejaVuSansMono/Regular/complete/${ESCNERDFONT}"

curl -fLo "${BASEDIR}/mash/fonts/fontawesome-webfont.ttf" --create-dirs \
    https://github.com/CollageLabs/Font-Awesome/raw/v4.7.0/fonts/fontawesome-webfont.ttf

echospaced "Installing Mash plugins ..."
cd "${BASEDIR}/mash/plugins"

git clone --depth 1 --single-branch --branch develop \
    https://github.com/CollageLabs/mash

for REPO in ${PLUGINREPOS}; do
    git clone --depth 1 --single-branch ${REPO}
done

curl -fLo "${BASEDIR}/mash/plug/autoload/plug.vim" --create-dirs \
    https://github.com/CollageLabs/vim-plug/raw/0.9.1/plug.vim

echospaced "Generating tar distribution ..."
cd ${BASEDIR}
tar -czf mash.tar.gz mash
rm -rf "${VIM_TEMPDIR}" "${URXVT_TEMPDIR}" mash
