# Keybinding modes: GUI pass

A local check that both first-launch keybinding modes work in a real Mash Terminal
window. It is not wired to CI: it needs a desktop session and drives real
keystrokes. The automated side lives in `test_native_keybindings.py`,
`test_keybinding_modes.py`, `test_linux_keybindings.py` and `test_menu_chords.py`,
which the PR workflow runs.

Run it after changing anything in:

- `packaging/defaults/herdr/`, `packaging/defaults/ghostty/` or `packaging/defaults/fresh/`;
- `packaging/defaults/pi/keybindings.json` or the quick-reference sheets;
- `packaging/helpers/mash-seed-sync`;
- the fork's menus or `mash_send_key`.

Never use the user's `~/.mash`: the helper below seeds a throwaway instance.

## Set up (Linux)

1. Build: `packaging/build-linux.sh` (add `MASH_SKIP_GHOSTTY=1` when only
   packaging changed). For a fork change, build the fork and pass the binary as
   `MASH_TERMINAL`.
2. Seed and launch one mode at a time:

   ```bash
   packaging/tests/keybinding-gui-env.sh native     # or: mash
   /tmp/mash-kb-native/launch &
   . /tmp/mash-kb-native/env.sh                       # herdr CLI now talks to it
   ```

   The window starts under XWayland (`GDK_BACKEND=x11`) so cua-driver can target
   it by PID.
3. Drive it with cua-driver on its X11 backend: run `cua-driver serve` without
   `CUA_DRIVER_RS_ENABLE_WAYLAND`. GNOME Wayland has no target-addressable route,
   so key delivery needs `delivery_mode: "foreground"`. Find the window by the
   terminal's PID, not its title: Herdr retitles it.
4. Verify through state, not pixels, wherever possible:
   - `herdr tab list` / `herdr pane list` / `herdr pane read <pane> --source visible`;
   - Fresh's status line (`Ln, Col`) in `herdr pane read`.

   Screenshots can be stale, so write each one to a new file.
5. Menus: click the "Main Menu" toggle by its `element_token` through the
   cua-driver MCP tools. The CLI scopes snapshots per call, so tokens don't
   survive between CLI invocations. Submenu items have no AT-SPI labels; take
   their order from a screenshot of the popup.

## What to check

| Mode | Check | Expected |
| --- | --- | --- |
| Native | `Ctrl+B c`, `Ctrl+B n`/`p`, `Ctrl+B 1` | tab created, cycled, selected |
| Native | `Ctrl+B v`, `Ctrl+B x`, `Ctrl+B Shift+X` | split, pane closed, tab closed |
| Native | `Ctrl+B t` / `a` / `Shift+C` | dev, agent, plain tab |
| Native | `Ctrl+B f`, `Ctrl+B ;` | file finder popup; command palette fires |
| Native | Fresh: `Ctrl+End`, `Ctrl+G`, `Ctrl+Home`, `Ctrl+→`, `Ctrl+D`, `Ctrl+E` | Fresh's stock behaviour |
| Native | `Ctrl+B` alone in Fresh | Herdr takes it; Fresh's explorer does not toggle |
| Native | Pi: `Ctrl+↑` / `Ctrl+↓`, then `Ctrl+Shift+↑` / `Ctrl+Shift+↓` | first pair jumps between messages; second pair does nothing (Ghostty's stock `jump_to_prompt` keeps them on Linux, and Mash removed its scrollback UI). The Linux Native sheet says so. |
| Native | Menu: Settings, Reload Configuration, Go › Previous/Next Tab | settings open, config reloads, tabs cycle; labels show `Ctrl+B …` |
| Native | Seeded files | no `keybind` lines in Ghostty, `mash-keybindings = native`, no Fresh `keybindings`, no `pi/agent/keybindings.json` |
| Cursor-style | `Ctrl+B c` | nothing (no prefix) |
| Cursor-style | `Ctrl+Shift+T`, `Ctrl+Tab`, `Ctrl+Shift+Tab` | plain tab, next/previous tab |
| Cursor-style | Menu: Go › Next Tab; labels | tab cycles; labels unchanged (`Ctrl+,`, `Shift+Ctrl+,`) |
| Either | With the window open: write the other mode's files, then `kill -USR2 <terminal pid>` | menu labels and chords switch to that mode, with no duplicated items |

That last row is the first-launch path: the wizard runs inside an already-open
window, so `herdr-pane` signals its own terminal (`MASH_TERMINAL_PID`) once setup
finishes. `test_wizard_mode_reload.sh` covers the signalling; only the reloaded
menus need eyes.

The review tab needs the bundled reviewr plugin, which the throwaway instance
doesn't link. Check that its key fires (temporarily point the command at a log
file), not that the tab opens.

## macOS

The same table applies with the macOS keys: `⌘` for Cursor-style chords, and
`⌃B …` for Native. Run it by hand on a Mac build. The Native menu bar items show
their `⌃B …` sequence in the title instead of a key equivalent.

## Clean up

```bash
for r in /tmp/mash-kb-mash /tmp/mash-kb-native; do (. $r/env.sh; herdr server stop); done
```

Then close the windows. Inspect and remove only the exact fixture directories you created; the helper refuses to overwrite an existing directory.
