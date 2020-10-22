
image:

	@docker build --rm -t collagelabs/subliminal-view:build .

build:

	@docker run -it -w ${PWD} -v ${PWD}:${PWD} collagelabs/subliminal-view:build bash build.sh

