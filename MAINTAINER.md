# Maintainer Guide

Quick reminders for Mash. The workflow skills live in the agent's global skill
directory (`mash-*`), not in this repo; fleet setup lives in **maintainer-tools**.

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

**The release carries no artifacts yet.** The GH release publishes the tag and
the changelog only; nothing builds or attaches `Mash.dmg` (see below).

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
| `release.yml` | release published | Runs `scripts/preflight.sh <tag>` at that tag, then dispatches `artifacts.yml`. |
| `artifacts.yml` | dispatched by `release.yml` | Builds, signs, notarizes and staples `Mash.dmg` on a GitHub-hosted `macos-26` runner, checks the artifact, and attaches it to the release with checksums. |
| `keepalive.yml` | schedule | Keeps the repo's scheduled workflows alive. |

There is no `pr.yml` / `push.yml`: nothing gates pull requests yet, so a release
branch is not automatically checked before `release.sh` waits on CI.

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
Ghostty fork at a fixed commit, **two** skills checkouts at fixed commits
(`mash-programming-skills` and `mash-design-skills`, both required by the build),
and the Metal Toolchain (downloaded per run, ~840 MB).

## Not built yet

The DMG pipeline runs in CI as above. `packaging/release.sh` can also be run by
hand on a maintainer machine with Xcode, the Metal toolchain, the Ghostty fork,
Zig and Apple credentials in `.env`.

## One-time GitHub setup

- `master` — restrict pushes.
- Tags — restrict creation to maintainers.
- Secret scanning and push protection are worth enabling: this repo is public
  and the build consumes Apple credentials.
