# >>> maintainer-tools:ops-docker BEGIN
# Managed by maintainer-tools 0.4.4. Do not edit directly.

PROJECT_NAME ?= mash
all_ps_hashes = $(shell docker ps -q)

image:
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml build \
		--build-arg UID=$(shell id -u) \
		--build-arg GID=$(shell id -g)

start:
	@if [ -z "$(img_hash)" ]; then\
		make image;\
	fi
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml up \
		--remove-orphans --no-build --detach

stop:
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml stop

down:
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml down \
		--remove-orphans

destroy:
	@echo
	@echo "WARNING!!!"
	@echo "This will stop and delete all containers, images and volumes related to this project."
	@echo
	@read -p "Press ctrl+c to abort or enter to continue." -n 1 -r
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml down \
		--rmi all --remove-orphans --volumes

cataplum:
	@echo
	@echo "WARNING!!!"
	@echo "This will stop and delete all containers, images and volumes present in your system."
	@echo
	@read -p "Press ctrl+c to abort or enter to continue." -n 1 -r
	@if [ -n "$(all_ps_hashes)" ]; then\
		docker kill $(shell docker ps -q);\
	fi
	@docker compose -p $(PROJECT_NAME) -f docker-compose.yml down \
		--rmi all --remove-orphans --volumes
	@docker system prune -a -f --volumes
# <<< maintainer-tools:ops-docker END

# >>> maintainer-tools:ops-release BEGIN
# Managed by maintainer-tools 0.4.4. Do not edit directly.

release:
	@./scripts/release.sh $${VERSION_TYPE}

release-patch:
	@./scripts/release.sh patch $${APP_NAME}

release-minor:
	@./scripts/release.sh minor $${APP_NAME}

release-major:
	@./scripts/release.sh major $${APP_NAME}



undo-release:
	@: "$${VERSION:?Set VERSION=x.y.z before running make undo-release}"
	@VERSION=$${VERSION} ./scripts/rollback.sh release
# <<< maintainer-tools:ops-release END

# Not managed by maintainer-tools: this repo's release gate. It runs the same
# script as .github/workflows/release.yml, so local and CI cannot drift apart.
release-preflight:
	@./scripts/preflight.sh

# Every test in the repository, on any platform that can host them. This is the
# single entry point CI calls, so a suite cannot be skipped in one lane only.
test:
	@./scripts/test.sh

# Native Linux package for this machine's architecture. Runs on Ubuntu 24.04
# x86_64 or arm64 only; the macOS build stays in packaging/build.sh.
package-linux:
	@./packaging/build-linux.sh

# Audit a built package without installing it.
verify-linux:
	@./packaging/tests/verify-linux-installed.sh $${DEB:?Set DEB=dist/letsmash_<version>_<arch>.deb}
