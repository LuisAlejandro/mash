
image:

	@docker build --rm -t collagelabs/mash:build .

build:

	@docker run -it -w ${PWD} -v ${PWD}:${PWD} collagelabs/mash:build bash build.sh

clean:

	@rm -rfv ./mash ./ui/search

install:

