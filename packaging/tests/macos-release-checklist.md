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
| Both architectures | Each release before 1 September 2027 carries `Mash-<version>-mac-arm64.dmg` and `Mash-<version>-mac-amd64.dmg`, each notarized and stapled; the Intel one is checked on Intel hardware |

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
| Terminal | Mash.app is the terminal: no `Mash Terminal.app` inside the bundle; About, Hide and Quit say Mash; Dock icon and name are Mash; no Ghostty tabs, splits, palette, Quick Terminal or New Window |
| One window | with Mash open, its Dock icon, Spotlight and `open -a Mash` each bring the one window forward; no second window or Dock tile appears. Closing the window quits Mash |
| Restart restores Mash | with Mash open, restart the Mac with "Reopen windows" ticked: Mash comes back with its workspaces, not a blank or missing window |
| Setup failure is visible | quit Mash, `mv ~/.mash ~/.mash.keep && touch ~/.mash`, open Mash: an alert says Mash could not start instead of the app vanishing; then `rm ~/.mash && mv ~/.mash.keep ~/.mash` |
| Menus | File, Edit, View, Go, Tools and Help show Mash's commands with their chords; picking one acts once, in that window only |
| Notifications | an agent finishing work raises a notification titled with the agent, from **Mash** with the Mash icon; macOS asks for notification permission once; clicking it focuses that pane |
| Dictation | macOS asks for microphone access on first use; dictated speech is transcribed, not reported as "no speech detected" |
| Pi project config | in a project with `.mash/settings.json` (for example a distinct `defaultThinkingLevel`), Pi applies it after the trust prompt; a `.pi/settings.json` beside it is ignored |
| Shell | a new pane shows the Starship prompt, completion works in zsh, bash and fish, and `viu` and `latexindent` run |
| Editor | Fresh opens files from the file finder and right-click reaches Fresh, not Herdr |
| Clipboard and mouse | copy, paste, selection and scrolling work in a shell pane and in Fresh |
| Fonts | with no extra fonts installed, set `~/.mash/setup/language` to each of ja, ko, zh-CN and th in turn and relaunch: the wizard, a Herdr pane, Fresh and Pi's replies show that language's glyphs, never boxes. macOS supplies the fallbacks, so nothing is packaged for it; this row is the only proof that they are reached |
| Self-update journey | covered by the blocking sign-off in `linux-release-checklist.md`: a disposable account, a notarized pair, mid-install relaunches, About Mash on the new version, no surviving old-bundle process, refusal and post-exchange recovery paths, and the 0.2.1/0.2.2 legacy transition |

**Blocking:** do not tag the release until every row passes. Record anything
skipped, and why, on the release.
