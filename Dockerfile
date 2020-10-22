FROM dockershelf/debian:buster
LABEL maintainer "Luis Alejandro Martínez Faneyth <luis@luisalejandro.org>"

RUN useradd -ms /bin/bash build
RUN apt-get update && \
    apt-get install \
        imagemagick librsvg2-bin build-essential git debootstrap fakechroot \
        fakeroot curl apt-transport-https python3 python3-dev dpkg-dev

USER build
CMD ["bash"]