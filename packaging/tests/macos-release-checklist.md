# macOS release checklist

The macOS counterpart to `linux-release-checklist.md`. Run it on a signed,
notarized `dist/Mash.dmg` before tagging a release, on a real Mac. Every row in
the manual sections needs a person at the keyboard; CI cannot sign them off.

## Build the release artifact

Test the DMG a user downloads, not `dist/Mash.app`. `packaging/build.sh` signs
ad hoc, and two behaviours depend on the real Developer ID signature: the
microphone prompt (the hardened-runtime entitlement on `Mash.app`) and the
notification identity (Notification Center keys it to the signed bundle).

```bash
make test && make release-preflight
./packaging/release.sh        # signed, notarized, stapled dist/Mash.dmg
```

`release.sh` reads Apple credentials from the repo-root `.env`, needs the Ghostty
fork checked out at the commit `packaging/assets.json` pins, and takes about an
hour, most of it notarization.

The bundle version comes from `VERSION`. A build before `make release-*` carries
the previous version, so installing it over that release is a same-version
reinstall, not an upgrade; note which one was tested.

## Automated

| Check | How |
| --- | --- |
| Suites | `make test` on the source tree |
| Release inputs | `make release-preflight` |
| Signature and notarization | `release.sh` verifies every Mach-O and nested bundle is Developer ID signed, hardened, and timestamped, then staples the ticket |
| Installed bundle matches source | `packaging/tests/verify-installed.sh` after installing: shipped helpers, defaults, code signature, microphone entitlement and purpose string, and the Pi project directory |
| Gatekeeper | `spctl --assess --type open --context context:primary-signature -v dist/Mash.dmg` |

## Upgrade over an existing install

Back up `~/.mash` first; it is live user data.

```bash
ditto ~/.mash ~/mash-backup-$(date +%Y%m%d)
```

Quit Mash, open `dist/Mash.dmg`, drag Mash into Applications and replace, then
launch it.

| Check | Expected |
| --- | --- |
| Data survives | workspaces, Pi sessions, credentials and edited configs under `~/.mash` are unchanged |
| Edited defaults kept | a seeded file you edited by hand keeps your edit; untouched seeded files may refresh |
| `verify-installed.sh` | exits 0 |
| Version shown | About Mash and the Herdr tab-bar label show the bundle version |

## Fresh install

Use a second macOS user account so your own `~/.mash` is untouched. Mash keeps
its data under the real home directory, so a new account is the only clean first
launch. Delete the account afterwards.

| Check | Expected |
| --- | --- |
| First launch | Gatekeeper opens the notarized app without a warning |
| Wizard | setup completes; the shortcut step offers the Mash (Cursor-style) and true-native options |
| Each shortcut mode | run setup once per mode, then follow `keybinding-modes-gui-pass.md` for that mode |
| Seeding | `~/.mash` is created mode 0700 and holds the seeded configs and agent directory |

## Manual sign-off

| Area | Check |
| --- | --- |
| Terminal | the terminal is `Mash Terminal.app`; About, Hide and Quit say Mash; Dock icon and name are Mash; no Ghostty tabs, splits, palette or Quick Terminal; New Window opens a second Mash instance |
| Menus | File, Edit, View, Go, Tools and Help show Mash's commands with their chords; picking one acts once, in that window only |
| Notifications | an agent finishing work raises a notification titled with the agent, from **Mash** with the Mash icon; macOS asks for notification permission once; clicking it focuses that pane |
| Dictation | macOS asks for microphone access on first use; dictated speech is transcribed, not reported as "no speech detected" |
| Pi project config | in a project with `.mash/settings.json` (for example a distinct `defaultThinkingLevel`), Pi applies it after the trust prompt; a `.pi/settings.json` beside it is ignored |
| Shell | a new pane shows the Starship prompt, completion works in zsh, bash and fish, and `viu` and `latexindent` run |
| Editor | Fresh opens files from the file finder and right-click reaches Fresh, not Herdr |
| Clipboard and mouse | copy, paste, selection and scrolling work in a shell pane and in Fresh |
| Self-update notice | covered by the blocking sign-off in `linux-release-checklist.md`; it needs an older signed build that already contains the updater, so 0.1.1 cannot exercise it |

**Blocking:** do not tag the release until every row passes. Record anything
skipped, and why, on the release.
