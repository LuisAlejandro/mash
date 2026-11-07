# Mash on Intel Macs (x86_64)

This document describes the changes that let Mash be **built and run on Macs
with an Intel processor**. The official release ships a DMG for Apple silicon
(arm64) only and `.deb` packages for Linux, and `packaging/build.sh` refused to
run anywhere but arm64.

> **Status: experimental.** There is no DMG or release for Intel: the app is
> built from source. It is ad-hoc signed rather than signed with a Developer ID,
> it is not notarized, and auto-update is disabled.

- Base version: **0.3.0** (`VERSION` is not modified).
- Tested on an Intel Core i9 MacBook Pro running macOS 26.
- Minimum declared by the app: macOS 14.

## What differs from the official build

| Area | Official build (arm64) | Intel build |
| --- | --- | --- |
| Build target | `macos-arm64` | `macos-amd64` (arm64 is unchanged) |
| Distribution | Signed, notarized DMG | Locally built, ad-hoc signed `dist/Mash.app` |
| Auto-update | Enabled | **Disabled** (there is no Intel release channel) |
| Notifications | The plugin's arm64 `terminal-notifier` | `terminal-notifier` 2.0.0 x86_64, pinned in the manifest |
| `sentrux` | Available | **Not available** (upstream only publishes arm64) |
| `latexindent` | Available | **Not available** (upstream only publishes arm64) |
| Voice dictation | `transcribe-cpp` with Metal | `transcribe-cpp`, CPU only (`darwin-x64-cpu`) |

## Changes by area

### 1. `macos-amd64` target in the manifest

- `packaging/assets.json`: new `macos-amd64` entry in `targets` and
  `supportedTargets`, and x86_64 artifacts with `url`, `sha256`, `archive` and
  `member` for `herdr`, `node`, `python`, `lazygit`, `lazydocker`, `pet`, `viu`,
  `atuin`, `gh`, `starship`, `rust`, `go`, `rust-analyzer`, `marksman`, `texlab`
  and `cua-driver`. Ghostty gains `frontends.macos-amd64: swift`.
- The `sha256` values were cross-checked against the checksums each provider
  publishes (GitHub API, Node's `SHASUMS256.txt`, `go.dev`, Rust's `.sha256`).
  `pet` and `terminal-notifier` (old releases) publish no digest.
- `marksman` reuses the arm64 binary: it is universal (x86_64 + arm64).
- `herdr` uses the `herdr-macos-x86_64` release binary, which only links system
  libraries. On arm64 the Homebrew bottle is still used.
- `packaging/pins.txt` was regenerated with `assets.py pins` (it gains
  `terminal-notifier`).
- `packaging/assets.py`: new `applies <component> <target>` command. It returns
  `0` if the component applies to the target, `4` if the manifest scopes it out
  of that target, and `1` if the component is unknown.

### 2. Build (`packaging/build.sh`, `packaging/carry.sh`)

- `build.sh` accepts `arm64` and `x86_64`, and the `macos-arm64` and
  `macos-amd64` targets.
- Herdr: when the URL is not a Homebrew registry URL (`ghcr.io`), the binary is
  downloaded with `mash_fetch_pinned` instead of being extracted from a bottle.
- Zig: the helper URL depends on the architecture and, if
  `/Volumes/Documents/Software/tools/zig-0.16.0/zig` does not exist,
  `~/Development/tools/zig-0.16.0/zig` is used.
- Ghostty (`mash_build_ghostty`), **on `macos-amd64` only**: built with
  `-Dxcframework-target=native` (half the Zig work of the universal framework)
  and `xcodebuild` receives `ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES`. The
  architecture has to be pinned because the Xcode project only sets
  `ONLY_ACTIVE_ARCH` for Debug, and a Release build would also try to link arm64
  against an x86_64 framework.

### 3. Notifications

The `herdr-terminal-notifier` plugin ships a `terminal-notifier` built for arm64
only. The manifest gains a `terminal-notifier` 2.0.0 component (the official
`julienXX/terminal-notifier` x86_64 release), and `mash_build_plugins` replaces
the executable inside `HerdrNotify.app` when the manifest pins one for the
target. It is the same version (2.0.0) the plugin uses on arm64, and the ad-hoc
signature is redone as before.

### 4. Auto-update disabled

- `build.sh` writes `Contents/Resources/updates-disabled` when the target is not
  `macos-arm64`.
- `packaging/helpers/mash-update-notice` honours that marker: it does not query
  the GitHub API or offer downloads. It is a single switch for both the
  automatic check (started by `herdr-pane`) and the manual one (`Cmd+Shift+U`,
  the "Check for Updates…" menu item); the manual one shows "Updates are
  disabled in this build".
- `packaging/plugins/mash-update-notice/notice.sh` renders that state.
- `packaging/helpers/mash-update-processes.c` only looked for the arm64 slice of
  a Mach-O executable; it now uses the host's own slice (`__arm64__` or x86_64).
- `mash-update-verify` still names `Mash-<v>-mac-arm64.dmg`, but it is
  unreachable because the update notice is never shown.

### 5. Tools unavailable on Intel, and a wizard fix

`sentrux` and `latexindent` only publish an arm64 macOS binary, so the manifest
scopes them out of `macos-amd64` with `targets`. That exposed a bug: the tools
page checks them by default, and the first-launch wizard treated any non-zero
exit from `mash-tool-install` as fatal, which would have stopped the "Install
pinned tools" step on Intel.

- `packaging/helpers/mash-tool-install`: exits with code **4** ("not available
  on this platform") when `assets.py applies` says so; every other failure still
  exits with 1.
- `packaging/wizard/main.rs`: code 4 is a non-fatal notice
  (`ToolOutcome::Unavailable`). The summary names the tools, for example:
  `3 installed, 0 provided by the system, not available for this platform: latexindent, sentrux`.

Effect for the user:

- Without `sentrux` the structural-analysis gate and its MCP server are lost. The
  planning, work and QA skills account for this and record `SENTRUX: unavailable`.
  The `sentrux` entry in `mcp.json` points to a binary that does not exist, as it
  would if the user had unchecked the tool.
- Without `latexindent`, LaTeX is not formatted on save in Fresh; `texlab` still
  works. Workaround: `brew install latexindent`.

### 6. Tests

- `packaging/tests/test_assets.py`: `macos-amd64` joins `ALL_TARGETS`; new tests
  check that Intel never resolves an arm64 artifact, the exclusions, and the
  `applies` command.
- `packaging/tests/test_mash_update_notice.sh`: cases for the marker (automatic
  and manual). They were confirmed to fail against the original helper.
- `packaging/helpers/tests/test-mash-tool-install.sh`: cases for exit code 4 and
  exit code 1; the block that uses the real network understands excluded
  components.
- `packaging/wizard/main.rs`: 3 unit tests for `tool_outcome` and
  `tools_summary`.

## How to build

Requirements outside the repository (the default locations `build.sh` expects):

| Requirement | Detail |
| --- | --- |
| Full Xcode | Tested with Xcode 26.6 and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) |
| Zig 0.16.0 | At `~/Development/tools/zig-0.16.0/zig`, or set `MASH_ZIG`. The exact version is required |
| Ghostty fork | `LuisAlejandro/ghostty` at commit `6bbdef7`, in `~/Development/ghostty` or at `MASH_GHOSTTY_SRC` |
| Skills | `LuisAlejandro/mash-programming-skills` 0.6.0, in `~/Development/mash-programming-skills` or at `MASH_SKILLS_SRC` |
| `git-lfs` | Some plugins keep images in LFS; with `filter.lfs.required=true` in `~/.gitconfig`, git fails without it |
| Toolchains | Rust and Go are downloaded, pinned, by the build itself |

```sh
caffeinate -dimsu bash packaging/build.sh        # produces dist/Mash.app
RUST_TEST_THREADS=4 make test                    # see the note below
```

- Rough duration on an i9-9980HK: ~45 min cold; `make test`, ~5 min.
- `build.sh` deletes `dist/.build` on start (toolchains are downloaded again)
  but keeps `dist/.cargo-target` if it fails, so a retry recompiles little.
- `build.sh` builds the menu into the terminal from the fork itself; it does not
  patch the checkout, so the Ghostty tree stays as the pin left it.
- Homebrew no longer publishes bottles for Intel, so installing tools (for
  example `git-lfs`) compiles from source.

## Verification

- `make test`: 64 suites pass with no failures; 4 are skipped because `herdr`
  and Pi are not on the `PATH`.
- `build.sh` finishes with `exit 0`. In `dist/Mash.app` all 47 Mach-O binaries
  include x86_64 (the only ones that also carry arm64 are npm-package prebuilds
  that ship an x64 twin), the ad-hoc signature verifies with
  `--deep --strict`, and herdr, node, python, gh, lazygit, starship, atuin, viu
  and fresh run at their pinned versions.
- Real first launch: the wizard completed Homebrew, npm, Python and CUA Driver,
  and the pinned-tools step ended with
  `3 installed … not available for this platform: latexindent, sentrux` without
  aborting.

## Limitations and unverified points

- **Timeout-bound tests:** with the default thread count, 2 `provider_page`
  tests (`catalog_flow_keeps_credential_provider_separate_from_fallback_model`
  and `custom_api_reaches_the_stdin_bridge_and_compact_mouse_target`) fail on a
  16-thread laptop because they wait on a fake `node` with a 3 s deadline. They
  fail the same way on the unmodified `develop`; with `RUST_TEST_THREADS=4` all
  199 pass.
- **Not verified when this was written:** memory installation (Hindsight), voice
  dictation (CPU only, so presumably slower than with Metal), actual delivery of
  notifications, and keyboard shortcuts.
- There is no Intel CI: the repository's workflows are still arm64 and Linux.
- Every component version bump needs its `macos-amd64` artifact and hash renewed
  by hand.

## Keeping the Intel target current

When a component's version is bumped, add its x86_64 artifact to the
`macos-amd64` block with the same `member`, adjusted for the architecture, and
cross-check the `sha256` against the one the provider publishes. Then:

```sh
python3 packaging/assets.py validate
python3 packaging/assets.py pins > packaging/pins.txt
python3 packaging/tests/test_assets.py
```

## Modified files

| File | Change |
| --- | --- |
| `packaging/assets.json`, `packaging/pins.txt` | `macos-amd64` target, x86_64 artifacts, `terminal-notifier` component, exclusions |
| `packaging/assets.py` | `applies` command |
| `packaging/build.sh` | Architecture guards, x86_64 Herdr, Zig, `updates-disabled` marker |
| `packaging/carry.sh` | Native Ghostty on Intel and replacement of the notifier binary |
| `packaging/helpers/mash-update-notice` | Honours `updates-disabled` |
| `packaging/plugins/mash-update-notice/notice.sh` | Message for disabled updates |
| `packaging/helpers/mash-update-processes.c` | Host Mach-O slice instead of a fixed arm64 |
| `packaging/helpers/mash-tool-install` | Exit code 4 |
| `packaging/wizard/main.rs` | Code 4 is non-fatal; summary and tests |
| `packaging/tests/test_assets.py`, `test_mash_update_notice.sh`, `packaging/helpers/tests/test-mash-tool-install.sh` | New and adjusted tests |
| `INTEL-MAC.md`, `README.md` | Documentation |
