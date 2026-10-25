# Linux release checklist

Two buckets, and every capability from the plan's R32 list appears in exactly
one of them. The automated bucket runs on ordinary hosted runners; the manual
bucket is the honest remainder and blocks publication until a maintainer records
it on the release.

Automated evidence is produced by `packaging/tests/linux-session-smoke.sh`, run
twice per architecture (xorg and wayland) in `artifacts.yml`. It proves the app
starts inside a synthetic session, seeds `~/.mash`, reaches that session's
display, claims the packaged app-id, and exits without leaving a server behind.

## Automated on hosted runners

| Capability | How it is proven |
| --- | --- |
| Launch and relaunch | launcher runs under Xvfb and weston headless; asserts it reaches the display and leaves no process |
| Seeding | 36 skills, configs, agent directory and shims present in a clean HOME |
| Shutdown | no Herdr process outlives the launcher |
| Package identity | `StartupWMClass` equals the class the terminal seeds |
| Keymap integrity | `test_linux_defaults.py`: no Command chords, no bare Ctrl+letter, no duplicates, action families present |
| Notifications | delivery mode asserted on the seeded Herdr config |
| Preview and reveal | `show_file` picks `xdg-open` off macOS; the Fresh patch carries a FileManager1 branch |
| Voice model selection | `test-mash-voice-model.sh` plans a model path without a network |
| Tool installation | `mash-tool-install` installs npm, binary and system strategies into `~/.mash` and the shims answer `--version` |
| Package contents | `verify-linux-installed.sh`: 26 checks over metadata, tree, icons, RPATH, linkage and identity |

## Manual sign-off before publishing

These need a real compositor and a real human, and claiming them from a headless
runner would be a lie. Record each on the release, with the desktop and session
used.

| Capability | Why it cannot be automated |
| --- | --- |
| Cross-window focus behaviour | a headless compositor has one window; assertions about focus stealing between workspaces need two |
| CUA background input into an occluded window | depends on compositor policy a headless backend does not implement |
| Notification delivery appearance | the session bus is observable, the notification surface is not |
| Font rendering | needs a real GPU/screen to judge, not only fontconfig discovery |
| Audio capture from a microphone | the harness uses a virtual source; hardware wake-up and permissions are a machine concern |
| Docker/design stack | needs a running Docker daemon, which the runner does not provide |

**Blocking:** publication requires every row above to be signed off. If a row
cannot be signed off for an architecture, that architecture must not be
published — a release with an untested platform is worse than a late one.
