# Contributing

Thank you for your interest in Mash. Contributions are welcome, and credit is given to everyone who helps improve the project.

## Types of Contributions

You can help by:

- Reporting bugs
- Fixing bugs
- Implementing features
- Improving documentation
- Submitting feedback on existing behavior

## Report Bugs

Report bugs through [GitHub Issues](https://github.com/LuisAlejandro/mash/issues).

Please include:

- Your operating system, version, and architecture (Apple silicon, amd64, arm64)
- On Linux, your desktop session (GNOME on Wayland or Xorg)
- How you installed Mash (DMG, `.deb`, or a local build)
- Steps to reproduce the problem
- Expected vs. actual behavior
- Relevant logs or screenshots

Mash keeps its data in `~/.mash`. That directory can contain credentials and session history, so review anything you copy from it before attaching it to an issue.

## Suggest Features

Before opening a feature request, check whether a similar issue already exists. Describe the problem you are solving, the behavior you want, alternatives you considered, and the scope you have in mind.

## Local Development

1. Fork and clone the repository.
2. Create a branch from `develop`.
3. Work with the host toolchain. This repository has no development container: the `docker`-based targets in `Makefile` come from a shared template and are not a build or test path for Mash.

Useful paths while working:

- `packaging/build.sh` and `packaging/build-linux.sh` assemble the macOS app and the Linux packages.
- `packaging/mash` and `packaging/linux/launcher` are the platform launchers; `packaging/launch-common.sh` seeds `~/.mash`.
- `packaging/wizard/` is the Rust first-launch wizard.
- `packaging/defaults/` holds the configuration shipped with the app. macOS and Linux often use separate files (`config` vs `config.linux`, `config.toml` vs `config.linux.toml`, `config.json` vs `config.linux.json`); check both when you change behavior.

Please do not edit the installed `/Applications/Mash.app` bundle, and do not reset or overwrite your own `~/.mash` directory to test a change: that is live user data.

## Quality Checks

From the repository root:

```sh
make test
make release-preflight
```

- `make test` runs every suite the repository ships: the Rust wizard, packaging contracts, launcher and helper shell tests, and the Node extension tests.
- `make release-preflight` runs the release gate: shell syntax, version agreement, the pinned artifact manifest, and the presence of every release input. It is the same script CI runs.

When you touch only the wizard, these are faster focused checks:

```sh
cargo test --locked --manifest-path packaging/wizard/Cargo.toml
cargo fmt --manifest-path packaging/wizard/Cargo.toml -- --check
```

Building the Linux package locally requires Ubuntu 24.04 and the toolchain described in [MAINTAINER.md](MAINTAINER.md).

## Pull Request Guidelines

- Keep changes focused and easy to review.
- Link related issues when applicable.
- Update documentation when user-facing behavior changes.
- Add or update tests when you change behavior; prefer the smallest runnable check that fails if the change regresses.
- Preserve user-owned data: changes to seeding must keep user-edited defaults and user-installed extensions, skills, and plugins intact.
- Do not commit secrets, `.env` files, signing keys, or local credentials.

## Maintainer Notes

Releases are handled by maintainers using the git-flow release scripts (`make release-patch`, `make release-minor`, `make release-major`, and `make undo-release`). Contributors should not publish artifacts, push release tags, or cut GitHub releases unless asked to do so by a maintainer.

See [MAINTAINER.md](MAINTAINER.md) for maintainer release workflow details.
