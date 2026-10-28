# Mash

Mash is a desktop workspace for AI-assisted coding. It brings a customized Ghostty terminal, Herdr workspaces, the Fresh editor, Pi, and pinned development tools into one app. Your settings and sessions live in `~/.mash`, separate from the tools you use outside Mash.

## Install

Download the latest [Mash release](https://github.com/LuisAlejandro/mash/releases/latest). Each release includes SHA-256 checksums alongside its installers.

| Platform | Release asset | Supported environment |
| --- | --- | --- |
| macOS | `Mash-<version>-mac-arm64.dmg` | Apple silicon, macOS 14 or newer |
| Linux | `letsmash-<version>-linux-amd64.deb` or `letsmash-<version>-linux-arm64.deb` | Ubuntu 24.04 with GNOME on Wayland or Xorg |

**macOS:** Open the signed, notarized DMG and copy Mash.app to Applications. Launch Mash from there.

**Linux:** Download the `.deb` for your architecture, then install it with APT:

```sh
sudo apt install ./letsmash-<version>-linux-amd64.deb
```

Use `linux-arm64` in the filename on arm64. The package configures Mash's [signed APT repository](https://apt.letsma.sh/) automatically; later releases arrive through normal system updates (`sudo apt update && sudo apt upgrade`). Other Linux distributions, desktops, and architectures are not supported by these packages.

On first launch, the setup wizard configures your workspace. Mash keeps its data under `~/.mash`; upgrades preserve user-edited configuration and user-installed resources. Removing the app or package does not delete that directory.

## Source layout

- `packaging/build.sh` assembles the macOS app; `packaging/build-linux.sh` assembles Linux packages. `packaging/build-common.sh` and `packaging/carry.sh` stage shared and platform-specific components.
- `packaging/mash` and `packaging/linux/launcher` are the platform launchers. `packaging/launch-common.sh` seeds the data directory; `packaging/helpers/mash-seed-sync` refreshes only unchanged Mash-owned defaults.
- `packaging/wizard/` contains the first-launch wizard. `packaging/defaults/` contains the settings and themes shipped with the app.
- `packaging/assets.json` pins the external components. `.github/workflows/` builds, verifies, and publishes releases.

For local checks, run `make test` and `make release-preflight`. Release artifacts are built in GitHub Actions; see [MAINTAINER.md](MAINTAINER.md) for build, signing, and publication details. See [HISTORY.md](HISTORY.md) for changes.

## License

Mash is licensed under [GPL-3.0](LICENSE). Bundled third-party components retain their own licenses.
