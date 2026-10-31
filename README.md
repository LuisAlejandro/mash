![](https://raw.githubusercontent.com/LuisAlejandro/mash/develop/branding/banner.svg)

---

[![](https://img.shields.io/github/release/LuisAlejandro/mash.svg)](https://github.com/LuisAlejandro/mash/releases) [![](https://img.shields.io/github/actions/workflow/status/LuisAlejandro/mash/push.yml)](https://github.com/LuisAlejandro/mash/actions/workflows/push.yml) [![](https://img.shields.io/discord/809504357359157288.svg?label=&logo=discord&logoColor=ffffff&color=7389D8&labelColor=6A7EC2)](https://discord.gg/4Wc7xphH5e) [![](https://cla-assistant.io/readme/badge/LuisAlejandro/mash)](https://cla-assistant.io/LuisAlejandro/mash)

Current version: 0.2.1

*Mash* is a desktop workspace for AI-assisted coding. It brings a customized Ghostty terminal, Herdr workspaces, the Fresh editor, Pi, and pinned development tools into one app. Your settings and sessions live in `~/.mash`, separate from the tools you use outside Mash.

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
- `packaging/mash` and `packaging/linux/launcher` set up `~/.mash` and the environment before the terminal starts; on macOS the terminal is Mash.app's own executable and calls `packaging/mash` itself. `packaging/launch-common.sh` seeds the data directory; `packaging/helpers/mash-seed-sync` refreshes only unchanged Mash-owned defaults.
- `packaging/wizard/` contains the first-launch wizard. `packaging/defaults/` contains the settings and themes shipped with the app.
- `packaging/assets.json` pins the external components. `.github/workflows/` builds, verifies, and publishes releases.

## Testing

Run the full suite and the release gate from the repository root:

```sh
make test
make release-preflight
```

Release artifacts are built in GitHub Actions; see [MAINTAINER.md](MAINTAINER.md) for build, signing, and publication details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report issues at [github.com/LuisAlejandro/mash/issues](https://github.com/LuisAlejandro/mash/issues).

## Releases

Changelog: [HISTORY.md](HISTORY.md). GitHub release blurbs: [RELEASE_DESCRIPTION.md](RELEASE_DESCRIPTION.md). Maintainers use `make release-patch`, `make release-minor`, `make release-major`, and `make undo-release` (see [MAINTAINER.md](MAINTAINER.md)).

## License

Mash is licensed under [GPL-3.0](LICENSE). Bundled third-party components retain their own licenses.

## Made with 💖 and 🍔

![Banner](https://raw.githubusercontent.com/LuisAlejandro/mash/develop/branding/author-banner.svg)

> Web [luisalejandro.org](http://luisalejandro.org/) · GitHub [@LuisAlejandro](https://github.com/LuisAlejandro) · Twitter [@LuisAlejandro](https://twitter.com/LuisAlejandro)
