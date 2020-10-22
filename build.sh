#!/usr/bin/env bash

set -ex

function echospaced() {
    printf "\n# %s\n" "${1}"
}

ICONSIZES="16 22 32 48 64 128 256 512"

BASEDIR="$(pwd)"
URXVT_TEMPDIR="$(mktemp -d)"
VIM_TEMPDIR="$(mktemp -d)"

BUILDER="luis@luisalejandro.org"
PLUGINREPOS="$(cat "${BASEDIR}/init.vim" | grep "Plug" | grep -v "subliminal-view" | awk -F"'" '{print "https://github.com/"$2".git"}')"
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

DEBIANSNDBX="${BASEDIR}/subliminal-view/sandboxes/debian"

PACKAGE_MANAGERS_DEPENDS="ruby python3-pip golang nodejs"
URXVT_BUILD_DEPENDS="libxt-dev libxrender-dev libx11-dev libxpm-dev groff-base \
                     autotools-dev xutils-dev libxft-dev chrpath libperl-dev \
                     libev-dev libstartup-notification0-dev libgtk2.0-dev"
VIM_BUILD_DEPENDS="libacl1-dev libgpmg1-dev autoconf debhelper libncurses5-dev \
                   libselinux1-dev libgtk2.0-dev libgtk-3-dev libxaw7-dev libxt-dev \
                   libxpm-dev libperl-dev tcl-dev python3-dev ruby ruby-dev lua5.2 \
                   liblua5.2-dev"

PYTHONPKGLIST="pylint pyflakes pep8 pydocstyle docutils yamllint vim-vint"
NODEPKGLIST="jshint jsonlint csslint sass-lint less dockerfile_lint"
RUBYPKGLIST="rubocop mdl sqlint"
GOPKGLIST="github.com/golang/lint/golint"

apt-get update
apt-get install ${URXVT_BUILD_DEPENDS} ${VIM_BUILD_DEPENDS}

mkdir -vp "${BASEDIR}/subliminal-view/bin"
mkdir -vp "${BASEDIR}/subliminal-view/urxvt"
mkdir -vp "${BASEDIR}/subliminal-view/plugins"

echospaced "Downloading Vim source ..."
git clone --depth 1 --branch v8.0.0300 --single-branch \
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

echospaced "Compiling Subliminal View UI ..."
cd "${BASEDIR}"
gcc $(pkg-config --cflags gtk+-3.0) "ui/search.c" -o "ui/search" $(pkg-config --libs gtk+-3.0)

echospaced "Copying Subliminal View source ..."
cp -vrf "${BASEDIR}/subliminal-view.sh" "${BASEDIR}/subliminal-view/subliminal-view"
cp -vrf "${BASEDIR}/subliminal-view.svg" "${BASEDIR}/subliminal-view/"
cp -vrf "${BASEDIR}/ui/search" "${BASEDIR}/subliminal-view/bin"
cp -vrf "${URXVT_TEMPDIR}/urxvt/src/rxvt" "${BASEDIR}/subliminal-view/bin"
cp -vrf "${URXVT_TEMPDIR}/urxvt/src/urxvt.pm" "${BASEDIR}/subliminal-view/urxvt"
cp -vrf "${VIM_TEMPDIR}/vim/src/vim" "${BASEDIR}/subliminal-view/bin"
cp -vrf "${VIM_TEMPDIR}/vim/runtime" "${BASEDIR}/subliminal-view/"
chmod +x "${BASEDIR}/subliminal-view/subliminal-view"

echospaced "Generating Subliminal View icons ..."
for SIZE in ${ICONSIZES}; do
    mkdir -p "${BASEDIR}/subliminal-view/icons/hicolor/${SIZE}x${SIZE}/apps"
    convert -verbose -background None -resize "${SIZE}x${SIZE}" \
        "${BASEDIR}/subliminal-view.svg" \
        "${BASEDIR}/subliminal-view/icons/hicolor/${SIZE}x${SIZE}/apps/subliminal-view.png"
done

echospaced "Generating Subliminal View fonts ..."
curl -fLo "${BASEDIR}/subliminal-view/fonts/${NERDFONT}" --create-dirs \
    "https://github.com/CollageLabs/nerd-fonts/raw/v1.0.0/patched-fonts/DejaVuSansMono/Regular/complete/${ESCNERDFONT}"

curl -fLo "${BASEDIR}/subliminal-view/fonts/fontawesome-webfont.ttf" --create-dirs \
    https://github.com/CollageLabs/Font-Awesome/raw/v4.7.0/fonts/fontawesome-webfont.ttf

echospaced "Installing Subliminal View plugins ..."
cd "${BASEDIR}/subliminal-view/plugins"

git clone --depth 1 --single-branch --branch develop \
    https://github.com/CollageLabs/subliminal-view

for REPO in ${PLUGINREPOS}; do
    git clone --depth 1 --single-branch ${REPO}
done

curl -fLo "${BASEDIR}/subliminal-view/plug/autoload/plug.vim" --create-dirs \
    https://github.com/CollageLabs/vim-plug/raw/0.9.1/plug.vim

fakechroot fakeroot debootstrap buster ${DEBIANSNDBX}

echo "deb https://deb.nodesource.com/node_14.x sid main" > "${DEBIANSNDBX}/etc/apt/sources.list.d/nodesource.list"
curl -fLo "${DEBIANSNDBX}/root/nodesource.gpg.key" https://deb.nodesource.com/gpgkey/nodesource.gpg.key

fakechroot fakeroot chroot ${DEBIANSNDBX} apt-get update
fakechroot fakeroot chroot ${DEBIANSNDBX} apt-get install gnupg
fakechroot fakeroot chroot ${DEBIANSNDBX} apt-key add /root/nodesource.gpg.key
fakechroot fakeroot chroot ${DEBIANSNDBX} apt-get install ${PACKAGE_MANAGERS_DEPENDS}
fakechroot fakeroot chroot ${DEBIANSNDBX} gem install ${RUBYPKGLIST}
fakechroot fakeroot chroot ${DEBIANSNDBX} pip install ${PYTHONPKGLIST}
fakechroot fakeroot chroot ${DEBIANSNDBX} npm install ${NODEPKGLIST}
fakechroot fakeroot chroot ${DEBIANSNDBX} go get -v ${GOPKGLIST}

echospaced "Generating tar distribution ..."
cd ${BASEDIR}
tar -czf subliminal-view_${VERSION}.tar.gz subliminal-view
rm -rf "${VIM_TEMPDIR}" "${URXVT_TEMPDIR}" subliminal-view