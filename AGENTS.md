# Mash repository guidance

This file is for agents changing **this repository**. Follow the user's request and applicable higher-priority instructions; do not treat the installed app or the user's data folder as source code.

## Boundaries

- Work in place on the current branch. A dirty tree is normal: preserve unrelated edits and untracked files. Do not stash, switch branches, commit, push, or initiate a release unless requested.
- Edit source under this repo, **not** the signed `/Applications/Mash.app` bundle. `~/.mash` is live user data, not a test fixture; do not reset or overwrite it to verify a change.
- Keep user-edited defaults and user-installed extensions, skills, and plugins intact. `packaging/helpers/mash-seed-sync` owns provenance-based updates of Mash-seeded files; changes to seeding need tests for both untouched defaults and user edits.
- Never put credentials, private keys, or local `.env` contents into tracked files or output logs.

## Code paths

- macOS: `packaging/build.sh` stages Mash.app, whose executable is the terminal from the Ghostty fork; on every launch it execs `packaging/mash` (installed as `Resources/bin/mash-launch`), which seeds `~/.mash`, exports the environment and execs the terminal back. Mash has one window on both platforms. Linux: `packaging/build-linux.sh` builds the `.deb`; `packaging/linux/launcher` starts it. `packaging/build-common.sh`, `packaging/carry.sh`, `packaging/launch-common.sh`, and `packaging/lib.sh` contain shared staging and isolation logic.
- `packaging/wizard/` is the first-launch UI. `packaging/defaults/` holds seeded configuration; macOS and Linux often use separate files (`config` versus `config.linux`, `config.toml` versus `config.linux.toml`, `config.json` versus `config.linux.json`). Check both when changing behavior or keys.
- External binaries and tools are pinned in `packaging/assets.json`; the Ghostty fork commit is also pinned in `.github/workflows/artifacts.yml`. Keep these in sync. Treat `packaging/plugins/` as a mix of Mash-owned and vendored code, and check staging before assuming a file ships.
- Mash isolates programs with environment variables such as `XDG_CONFIG_HOME` and `PI_CODING_AGENT_DIR`; it does **not** change the user's `HOME`. Do not redirect writes to the user's own `~/.pi`, `~/.config`, or `~/.hindsight`.

## Verification and release

- Run `make test` and `make release-preflight` for changes to packaged code. For the Rust wizard, `cargo test --locked --manifest-path packaging/wizard/Cargo.toml` and `cargo fmt --manifest-path packaging/wizard/Cargo.toml -- --check` are useful focused checks. Add the smallest runnable regression check for nontrivial behavior.
- There is no working Compose file at this repo root; the generated Docker targets in `Makefile` are not a build/test path. Use the host toolchain for local checks.
- CI builds a signed macOS DMG and both Linux `.deb`s, then publishes the latter through the signed APT repository. Do not cut a release or publish artifacts without explicit authorization. See [MAINTAINER.md](MAINTAINER.md) and `packaging/apt/README.md` for the release contract.
- Mash's APT repository is isolated from Dockershelf on the same host. Never modify Dockershelf's repository, signing key, nginx site, importer, or SSH configuration while working on Mash.
