# Mash on Intel Macs (x86_64)

Mash officially supports Intel Macs running macOS 14 through macOS 26 until **1 September 2027**.
Releases before that date include a signed, notarized `Mash-<version>-mac-amd64.dmg`, alongside the Apple silicon DMG.
Download the installer matching your architecture from [GitHub Releases](https://github.com/LuisAlejandro/mash/releases).
Both official macOS builds support in-app updates.

After Intel support ends, the last Intel DMG remains downloadable; continued source builds depend on a compatible Xcode, macOS SDK, and the availability of the pinned upstream components.
The retirement date is not a promise that future source revisions will continue to build on Intel.

## Official releases and local builds

| Area | Official Intel release | Local Intel source build |
| --- | --- | --- |
| Target | `macos-amd64` | `macos-amd64`, selected from the native build host |
| Distribution | Developer ID-signed, notarized DMG | `dist/Mash.app`; release signing and notarization are separate steps |
| Updates | Downloads the Intel DMG while the release carries one | An ad-hoc build has no signing Team ID, so it cannot offer a verified in-app replacement |
| Terminal frontend | Swift frontend, native x86_64 build | Same build path |
| Persistent data | `~/.mash` | Same location; a local build is not an isolated test profile |

`packaging/build.sh` assembles the application; `packaging/release.sh` owns release signing and notarization.
The build does not disable updates merely because the target is Intel.
The `Resources/updates-disabled` marker is for targets without an official release channel, and `mash-update-notice` also refuses in-app replacement of an unsigned/ad-hoc app.
The updater chooses the DMG for the running architecture and requires the expected signing identity.
A later release without an Intel asset offers no update to that Mac.

`.github/workflows/artifacts.yml` builds the official Intel artifact on an Intel runner until the retirement date, and gates publication on the required architecture assets.
The macOS release checklist is in `packaging/tests/macos-release-checklist.md`.

## Intel-specific limitations

- `sentrux` and `latexindent` have no manifest artifact for `macos-amd64`, so Mash does not install an arm64 binary in their place.
  The installer returns status 4 for a tool unavailable on the platform, and the wizard reports that outcome without treating it as a failed installation.
- Without `sentrux`, structural-analysis tooling is unavailable; workflows must report that rather than claim a structural check passed.
- Without `latexindent`, Fresh cannot run that LaTeX formatter on save; `texlab` remains available.
  A separately installed compatible `latexindent` can provide the formatter, but is not managed by Mash's pin.
- Intel voice dictation uses the CPU runtime (`darwin-x64-cpu`), not the Apple silicon Metal runtime.
- The Intel build pins native x86_64 GhosttyKit and Swift architectures; it does not try to link an arm64 frontend against an x86_64-only framework.

The target applicability and artifact checksums are authoritative in `packaging/assets.json`, not in this guide.

## Build from source

Use a native Intel macOS host with a full compatible Xcode installation and its Metal Toolchain.
The current CI Xcode selection is in `.github/workflows/artifacts.yml`; consult that workflow and `MAINTAINER.md` rather than relying on a historical Xcode version from a previous build report.
Homebrew availability and compilation time depend on the host's supported macOS version and package bottles.
Some upstream plugins use Git LFS for assets; if your Git configuration requires LFS filters, ensure `git-lfs` is available before cloning them.

| Input | Source of truth or override |
| --- | --- |
| Ghostty fork repository and exact commit | `packaging/assets.json`, component `ghostty`; checkout location via `MASH_GHOSTTY_SRC` |
| Programming skills release | `packaging/assets.json`, component `mash-programming-skills`; checkout location via `MASH_SKILLS_SRC` |
| Zig build tool | Build scripts and `.github/workflows/artifacts.yml`; executable override `MASH_ZIG` must match the required version |
| Metal Toolchain | Xcode component selection in the build; `MASH_METAL_TOOLCHAIN` can select its identifier |
| Rust, Go, and bundled programs | Downloaded and verified against manifest pins by the build |

From the repository root, build the application without publishing anything:

```sh
caffeinate -dimsu bash packaging/build.sh
```

The output is `dist/Mash.app`.
A supplied Ghostty checkout that differs from the manifest produces a warning for local experimentation; release CI requires the exact pinned commit.
Never copy local test changes into the signed installed `/Applications/Mash.app` bundle.
Launching a local build still uses the real `~/.mash` unless its own launcher explicitly provides a separate profile, so do not use it as a disposable verification fixture.

## Verification

Run the repository gates:

```sh
make test
make release-preflight
```

These commands run available suites and report platform/tool-dependent skips; an old recorded suite count is not proof that a new build passed.
Use the macOS release checklist for hardware, signing, notarization, and update sign-offs that mocked tests cannot establish.
The presence of an Intel artifact job does not replace testing that artifact on Intel hardware.

## Keeping the Intel target current

When a component changes, verify its `macos-amd64` artifact or explicit platform exclusion in `packaging/assets.json`.
Do not assume that an arm64-named artifact also contains x86_64: verify the actual upstream binary and checksums.
Regenerate the pin list and run the manifest checks after a deliberate pin change:

```sh
python3 packaging/assets.py validate
python3 packaging/assets.py pins > packaging/pins.txt
python3 packaging/tests/test_assets.py
```

Release and test workflows read the Ghostty commit from the manifest; do not add a second hardcoded commit to this guide or to those workflows.
For release authorization, signing secrets, and publication gates, follow `MAINTAINER.md`.
