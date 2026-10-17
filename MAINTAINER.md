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

**The release ships a DMG.** Publishing the GitHub release triggers `release.yml`,
which re-runs the gate at that tag and then dispatches `artifacts.yml` to build,
sign, notarize and staple `Mash.dmg` and attach it to the release with checksums.

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
| `artifacts.yml` | dispatched by `release.yml` | Builds, signs, notarizes and staples `Mash.dmg` on a GitHub-hosted `macos-26` runner, checks the artifact, and attaches it to the release with checksums. |
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
