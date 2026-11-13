![](https://raw.githubusercontent.com/LuisAlejandro/mash/develop/branding/banner.svg)

---

[![](https://img.shields.io/github/release/LuisAlejandro/mash.svg)](https://github.com/LuisAlejandro/mash/releases) [![](https://img.shields.io/github/actions/workflow/status/LuisAlejandro/mash/push.yml)](https://github.com/LuisAlejandro/mash/actions/workflows/push.yml) [![](https://img.shields.io/discord/1556678684063301682.svg?label=&logo=discord&logoColor=ffffff&color=7389D8&labelColor=6A7EC2)](https://discord.gg/Wk95fG7w2C) [![](https://cla-assistant.io/readme/badge/LuisAlejandro/mash)](https://cla-assistant.io/LuisAlejandro/mash)

Current version: 0.5.0

*Mash* is a desktop workspace for AI-assisted coding. It brings a customized Ghostty terminal, Herdr workspaces, the Fresh editor, Pi, and pinned development tools into one app. Your settings and sessions live in `~/.mash`, separate from the tools you use outside Mash. Mash runs in 15 languages: the setup wizard asks once, and its own screens, messages, popups and the terminal's menu bar follow that choice.

## Install

Download the latest [Mash release](https://github.com/LuisAlejandro/mash/releases/latest). Each release includes SHA-256 checksums alongside its installers.

| Platform | Release asset | Supported environment |
| --- | --- | --- |
| macOS | `Mash-<version>-mac-arm64.dmg` | Apple silicon, macOS 14 or newer |
| macOS | `Mash-<version>-mac-amd64.dmg` | Intel, macOS 14 through macOS 26. Supported until 1 September 2027 |
| Linux | `letsmash-<version>-linux-amd64.deb` or `letsmash-<version>-linux-arm64.deb` | Ubuntu 24.04 with GNOME on Wayland or Xorg |

**macOS:** Open the signed, notarized DMG for your Mac's architecture and copy Mash.app to Applications. Launch Mash from there. Apple silicon and Intel builds update themselves.

**macOS on Intel:** Intel support ends on 1 September 2027, when the toolchain that builds it retires; the last Intel DMG stays downloadable. Two tools with no Intel build are left out: `sentrux` and `latexindent`. Building from source, before and after that date, is covered in [INTEL-MAC.md](INTEL-MAC.md).

**Linux:** Download the `.deb` for your architecture, then install it with APT:

```sh
sudo apt install ./letsmash-<version>-linux-amd64.deb
```

Use `linux-arm64` in the filename on arm64. The package configures Mash's [signed APT repository](https://apt.letsma.sh/) automatically; later releases arrive through normal system updates (`sudo apt update && sudo apt upgrade`). Other Linux distributions, desktops, and architectures are not supported by these packages.

On first launch, the setup wizard configures your workspace. Mash keeps its data under `~/.mash`; upgrades preserve user-edited configuration and user-installed resources. Removing the app or package does not delete that directory.

## Language

Set `~/.mash/setup/language` to one line, `language=<code>`, to choose a language:
`bg` Български, `cs` Čeština, `de` Deutsch, `en` English, `es` Español,
`fr` Français, `it` Italiano, `ja` 日本語, `ko` 한국어,
`pt-BR` Português (Brasil), `ru` Русский, `th` ไทย, `uk` Українська,
`vi` Tiếng Việt, or `zh-CN` 简体中文. It takes effect on the next launch.
Herdr UI, Pi's own interface, third-party CLI tools, and language servers stay
in English.

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
