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
| GTK window startup | `linux-session-smoke.sh`: no GTK template-child error or panic while opening Mash under Xorg and Wayland; source-only Blueprint compilation cannot prove a window instantiates |
| Terminal input wiring | `linux-session-smoke.sh` reads Ghostty's effective config: mouse reporting and clipboard access remain enabled, with Ctrl+Shift+C/V bound to copy/paste; real delivery is checked below |
| Notifications | delivery mode asserted on the seeded Herdr config |
| Preview and reveal | `show_file` picks `xdg-open` off macOS; the Fresh patch carries a FileManager1 branch |
| Voice model selection | `test-mash-voice-model.sh` plans a model path without a network |
| Tool installation | `mash-tool-install` installs npm, binary and system strategies into `~/.mash` and the shims answer `--version` |
| Package contents | `verify-linux-installed.sh`: 26 checks over metadata, tree, icons, RPATH, linkage and identity |
| Repository configuration | `test_linux_package.py` contract-checks `postinst`/`postrm`; a real install is proven by `apt-upgrade-smoke.sh --deb <package>` writing `/etc/apt/sources.list.d/letsmash.sources` |
| Repository trust chain | `apt-upgrade-smoke.sh`: the published index verifies against the keyring the package ships, and apt resolves `letsmash` from `apt.letsma.sh` |
| Upgrade preserves state | `apt-upgrade-smoke.sh` after publication, plus `test_seed_ownership.sh` for the seeded-file rule (edited files kept, untouched defaults refreshed) |

## Manual sign-off before publishing

These need a real compositor and a real human, and claiming them from a headless
runner would be a lie. Record each on the release, with the desktop and session
used.

| Capability | Why it cannot be automated |
| --- | --- |
| Cross-window focus behaviour | a headless compositor has one window; assertions about focus stealing between workspaces need two |
| Mash Terminal menus and second instance | On both GNOME Xorg and Wayland, inspect the titlebar, main menu, and terminal right-click menu: no Ghostty tab/overview, split, command palette, find, Quick Terminal, inspector, or Change Title affordance; the main menu reads "About Mash Terminal"; New Window remains and opens another Mash instance with its own Herdr workspaces |
| Herdr input and clipboard | In a Herdr shell and a Fresh pane, verify mouse clicks, right-click routing, scrolling, selection copy and clipboard paste still work; the headless config check cannot prove event delivery |
| Mash menu items | Open the titlebar main menu: File, Edit, View, Go and Tools submenus and Settings, Reload Configuration, Detach and Mash Help each show their chord. Pick one item per submenu and confirm Herdr does what the shortcut does. With two Mash windows open, an item acts only in the window whose menu was used. Edit Herdr's config and pick Reload Configuration: the change applies without a restart, and Fresh panes are untouched. A chord rebound by the user leaves its menu item inert; that is expected |
| Update notice | On GNOME Xorg and Wayland, install an older `letsmash`, make a newer one the APT candidate (published, or a scratch repository as in `packaging/tests/apt-upgrade-smoke.sh`), and open Mash: one centered popup and one desktop notification name both versions and `sudo apt install --only-upgrade letsmash`, and any key closes the popup. Open a second window and relaunch: nothing appears. Delete `/etc/apt/sources.list.d/letsmash.sources`, run `apt-get update`, and relaunch: nothing appears. The popup is drawn by the attached client and the notification surface is not observable headlessly |
| CUA background input into an occluded window | depends on compositor policy a headless backend does not implement |
| Notification delivery appearance | the session bus is observable, the notification surface is not |
| Font rendering | needs a real GPU/screen to judge, not only fontconfig discovery |
| Audio capture from a microphone | the harness uses a virtual source; hardware wake-up and permissions are a machine concern |
| Docker/design stack | needs a running Docker daemon, which the runner does not provide |

**Blocking:** publication requires every row above to be signed off. If a row
cannot be signed off for an architecture, that architecture must not be
published — a release with an untested platform is worse than a late one.

## Companion macOS check for the same Ghostty trim

This is not a Linux publication gate. On an updated Mash.app, inspect File, View,
Window, Dock, and terminal context menus: New Window still creates a second Mash
instance, but Ghostty tabs, splits, palette, find, Quick Terminal, and inspector
are absent. Ask AppleScript to create a `new tab` or `split`; each must fail or do
nothing, without creating another Ghostty surface. Confirm copy/paste and Herdr
mouse input still work in a shell pane and in Fresh.

The app menu reads About Mash, Hide Mash, and Quit Mash, with no Check for Updates,
Make Ghostty the Default Terminal, or Help menu. Edit has no Undo or Redo, and View
and Window have no Change Terminal Title, Float on Top, or Use as Default; Show/Hide
All Terminals remains. Close a Mash window, then press Cmd+Z: nothing reopens and a
new icon click reuses the freed instance slot. The bundle carries no
`Sparkle.framework` and its Info.plist no `SU*` keys.

The menu bar adds Go, Tools and Help menus, and File, Edit and View carry Mash's
tab, workspace, pane and annotation commands, each showing its Herdr chord.
Choosing an item, or pressing its shortcut, does the Herdr command exactly once
in that window only. Settings opens Herdr's settings, Reload Configuration
reloads Ghostty and Herdr, and Detach closes the window and frees its instance.

**macOS self-update sign-off (blocking for a macOS release):** Install an older
Developer ID-signed Mash.app that already contains this updater in a writable
location, then publish a newer signed, notarized DMG. Builds predating this
feature (including 0.1.1) need one manual upgrade and cannot self-update. Launch the old app: a centered update
popup and a desktop notification appear once. Press `u`: the DMG downloads with
progress and is verified, then one confirmation names how many Mash windows
will close. With two windows open, confirm: both terminal windows and all
bundled Herdr servers exit, the installed app is exchanged, and the new Mash
reopens with a one-time confirmation of the running version. Check that
`~/.mash` workspaces, user edits and credentials are intact. Repeat using a
signed DMG from another Team ID and a read-only mounted DMG: verification must
reject the former before quitting, and the latter must show the notice without
an update key. The app on disk must remain usable after every refusal. A real
notarized pair is required; stub tests cannot prove Gatekeeper or process exit.
