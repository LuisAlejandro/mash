# Maintainer Guide

Quick reminders for Mash. The workflow skills come from two pinned checkouts,
`mash-programming-skills` and `mash-design-skills`, and are staged into the app
at `Contents/Resources/defaults/pi/skills` — they are not in this repo. Fleet
setup lives in **maintainer-tools**.

## Feature work

`mash-brainstorm` → `mash-plan` → `mash-work` → `mash-qa` → `mash-pr`. Repeat
until ready to ship. `mash-lint` runs lint/format/type-check scoped to the
session's changed files.

## Version

`VERSION` at the repo root is the **only** place the app version lives.
`packaging/build.sh` reads it into the bundle's `CFBundleShortVersionString` and
`CFBundleVersion`. `bumpversion` is its only writer — never edit it by hand, or
`.bumpversion.cfg` and `VERSION` will disagree and the release gate will fail.

## Release

From a **clean** `develop`:

| Step | Command / skill |
|------|-----------------|
| Interactive | `mash-release` (default **patch**; `minor` / `major` when needed) |
| Manual | `make release-preflight` then `make release-patch` (or `-minor` / `-major`) |
| Rollback | `VERSION=<version> make undo-release` |

`make release-preflight` runs `scripts/preflight.sh`, which checks that every
shipped script parses, that `VERSION`/.bumpversion.cfg/the tag agree, and that
the release inputs are all present. The same script is the CI gate, so the two
cannot drift. It needs no Apple tooling, no Docker and no network.

`make release-*` runs that same gate automatically before bumping anything, so a
bad tree stops the release instead of producing a tag that only CI rejects.

**The release ships three artifacts.** `make release-*` creates the release as a
**draft** and dispatches `release.yml` at that tag. It re-runs the gate and hands
off to `artifacts.yml`, which builds macOS arm64, Linux amd64 and Linux arm64,
attaches every file with one combined checksum manifest, attests the Debian
packages, and only then flips the draft public. A failed platform leaves an
unpublished draft, so users never see a release with missing files.

Publishing a release by hand in the GitHub UI builds nothing: the build is
dispatched by `scripts/release.sh`, not by the publish event.

## Before `make release-*`

- Tools: `git`, git-flow, `make`, `gh`, `bumpversion`, and a GPG signing key
  (`git config user.signingkey` — the bump commit is signed).
  Docker is **not** required: there is no `docker-compose.yml` here.
- Clean working tree. Both `scripts/release.sh` and `bumpversion` refuse to run
  otherwise.
- Post-bump hooks: `.bumpversion.cfg` → `[maintainer-tools]`. Mash has none —
  nothing else embeds the version.

## CI

| Workflow | Trigger | Does |
|---|---|---|
| `push.yml` | push to `develop`, `master`, `release/**` | Runs `scripts/preflight.sh`, then the helper and packaging tests. `release.sh` waits on this run for the release branch before merging. |
| `release.yml` | release published | Runs `scripts/preflight.sh <tag>` at that tag, then dispatches `artifacts.yml`. |
| `artifacts.yml` | dispatched by `release.yml` | Builds `Mash.dmg` on `macos-26` and both `letsmash` packages on `ubuntu-24.04` and `ubuntu-24.04-arm`, verifies each, combines checksums, publishes the draft. |
| `release.yml` | `workflow_dispatch` | Re-runs the gate at the tag, then dispatches `artifacts.yml`. |
| `keepalive.yml` | schedule | Keeps the repo's scheduled workflows alive. |

`push.yml` gates every push to a long-lived branch, including the `release/<version>`
branch `release.sh` publishes. It is the wait target (`RELEASE_CI_WORKFLOW`
defaults to its filename), so renaming or removing it makes `release.sh` poll for
45 minutes and then fail. There is no `pr.yml`: pull requests are not checked yet.

### Required secrets

| Secret | Used for |
|---|---|
| `MACOS_CERT_P12` | base64 of the Developer ID Application `.p12`, imported into a throwaway keychain |
| `MACOS_CERT_PASSWORD` | its password |
| `MASH_KEYCHAIN_PASSWORD` | any value; guards that throwaway keychain |
| `APPLE_ID` | notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | notarization |
| `APPLE_TEAM_ID` | notarization, and the signing identity name |

No secret is needed to read `mash-programming-skills`: that repo is public, so
CI clones it anonymously. It was made public only after its history was
rewritten to purge a leaked credential — see the pin in `artifacts.yml`.

Nothing here is checked in. This repo is public: keep credentials in these
secrets and in the gitignored `.env` for local runs, never in a tracked file.

### What the build pulls in

`artifacts.yml` pins all of it, so a release is reproducible: Zig `0.16.0`, the
Ghostty fork at a fixed commit, **two** skills checkouts pinned to a release tag
(`mash-programming-skills` and `mash-design-skills`, both required by the build),
and the Metal Toolchain (downloaded per run, ~840 MB).

Both skills repos cut releases and tag them, so the pin is a tag (`SKILLS_REF`,
`DESIGN_SKILLS_REF`) rather than a commit SHA: a tag names a released, tested
state; a commit only names where a branch happened to be. Bumping the pin means
cutting a release there first, then pointing `SKILLS_VERSION`/`SKILLS_REF` (and
the matching values in `packaging/carry.sh` and `packaging/pins.txt`) at it.

## Building the Linux package

On Ubuntu 24.04, natively:

```
make package-linux          # or ./packaging/build-linux.sh
make verify-linux DEB=dist/letsmash_0.1.0_amd64.deb
```

Needs the distro's GTK4/libadwaita development packages, `dpkg-dev`, `patchelf`,
`meson`/`ninja`, Zig 0.16.0, blueprint-compiler **0.16.x** (Ubuntu ships 0.12,
which Ghostty rejects; 0.20+ rejects Ghostty's `.blp` files), a Rust toolchain
and Go. The script fetches and checksum-verifies the pinned toolchains itself.

`dist/.cache` (or `MASH_BUILD_CACHE`) holds downloads, toolchains, Zig's and
cargo's caches. A cold build takes about fifteen minutes; a payload-only rebuild
about four. `MASH_SKIP_GHOSTTY=1` reuses the previously built terminal frontend.

Ghostty's GTK frontend is built from the pinned fork with
`packaging/patches/ghostty-gtk-branding.patch` applied, so the fork itself needs
no branding commit.

## Building the DMG by hand

The DMG pipeline runs in CI as above. `packaging/release.sh` can also be run by
hand on a maintainer machine with Xcode, the Metal toolchain, the Ghostty fork,
Zig and Apple credentials in `.env`. `packaging/build.sh` assembles `dist/Mash.app`
alone, without signing or notarizing.

## One-time GitHub setup

- `master` — the git-flow production branch; `release.sh` finishes each release
  onto it. Restrict pushes to it and to tags.
- Secret scanning and push protection are worth enabling: this repo is public
  and the build consumes Apple credentials.
