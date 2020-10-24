FROM dockershelf/debian:sid
LABEL maintainer "Luis Alejandro Martínez Faneyth <luis@luisalejandro.org>"

RUN apt-get update && \
    apt-get install \
        imagemagick librsvg2-bin build-essential git debootstrap fakechroot \
        fakeroot curl apt-transport-https python3 python3-dev dpkg-dev \
        ca-certificates gnupg sudo wget

RUN useradd --create-home --shell /bin/bash --uid 1000 build
RUN echo "build ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/build

RUN apt-get install \
        libxt-dev libxrender-dev libx11-dev libxpm-dev groff-base \
        autotools-dev xutils-dev libxft-dev chrpath libperl-dev \
        libev-dev libstartup-notification0-dev libgtk2.0-dev

RUN apt-get install \
        libacl1-dev libgpmg1-dev autoconf debhelper libncurses5-dev \
        libselinux1-dev libgtk2.0-dev libgtk-3-dev libxaw7-dev libxt-dev \
        libxpm-dev libperl-dev tcl-dev python3-dev ruby ruby-dev lua5.2 \
        liblua5.2-dev

RUN echo "deb https://deb.nodesource.com/node_14.x buster main" > /etc/apt/sources.list.d/nodesource.list
RUN curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource.gpg.key" | apt-key add -

RUN apt-get update && \
    apt-get install \
        ruby2.5 ruby2.5-dev python3-pip python3-setuptools python3-wheel \
        python3-distutils python3-virtualenv golang nodejs

USER build
CMD ["bash"]