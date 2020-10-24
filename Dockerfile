FROM dockershelf/debian:sid
LABEL maintainer "Luis Alejandro Martínez Faneyth <luis@luisalejandro.org>"

RUN apt-get update && \
    apt-get install \
        imagemagick librsvg2-bin build-essential git curl apt-transport-https \
        python3 python3-dev dpkg-dev ca-certificates gnupg sudo

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

USER build
CMD ["bash"]