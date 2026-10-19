# Retiring the personal agent setup

This retires the Herdr-based personal environment that Mash was built from.
It is run **by an agent inside the installed Mash**, never from the personal
setup itself.

`scripts/port-check.sh` does the work. Its rule: an item is quarantined only
when Mash already carries it. Everything else is reported and left alone.

## Hard rule

**Nothing is deleted.** `--apply` *moves* each verified item into a quarantine
folder. Deletion is a separate, later, human decision. Do not add `rm -rf`,
and do not empty the quarantine folder at the end of this runbook.

## Preconditions — confirm all four, stop if any fails

1. **Mash is installed, has been used, and still verifies.**
   `test -d /Applications/Mash.app && test -d ~/.mash`
   then `codesign --verify --deep --strict /Applications/Mash.app`. A bundle
   that fails here grew files after it was signed — Python bytecode is the usual
   cause — and is not a trustworthy base for retiring the launcher it replaces.
   `packaging/tests/verify-installed.sh` reports the same check in one command.
2. **This shell is inside Mash, not the personal setup.**
   `echo "$HERDR_SOCKET_PATH"` must contain `/.mash/run/`.
   If it contains `/.config/herdr`, stop — `port-check.sh` refuses anyway.
3. **The personal Herdr and its Ghostty windows are quit.** Otherwise moving
   `~/.config/herdr` pulls the config out from under a live server. Ask the
   owner to close them, then confirm
   `ps -ax -o command= | grep -F /opt/homebrew/bin/herdr` prints nothing but the
   grep itself. Use `ps`: `pgrep` does not show the ancestors of your own shell
   on macOS, so a live server started from it looks absent.
4. **A backup exists.** Time Machine snapshot, or a `tar` of `~/dotfiles`,
   `~/.pi`, `~/.agents` and `~/.config`. Ask the owner to confirm.

## Read-only first

```sh
cd /Volumes/Documents/Software/mash
./scripts/port-check.sh              # full plan
./scripts/port-check.sh --groups     # staging groups and sizes
```

Report the summary to the owner, then continue. An `UNVERIFIED` entry has no Mash
counterpart on disk and must not be touched. Stop and ask if one is not
accounted for below.

On the current app the expected result is **zero `UNVERIFIED`**. The three
Hindsight paths (`~/.local/bin/hindsight`, `~/.local/bin/hindsight-embed`,
`~/.local/share/uv/tools/hindsight-embed`) resolve to `SHARED` on their own,
because their evidence is `defaults/mash-config/hindsight-embed.env` in the
bundle. The design stack resolves the same way once `defaults/pi/skills/mash-design-setup`
is present. An `UNVERIFIED` entry anywhere is a real gap.

Those three Hindsight paths are also staged under the group named **`keep`**, and
`--groups` therefore prints `keep` with three items in it. Never pass
`--group keep`, and never run a bare `--apply` or `--apply --include-shared`
without a group filter: both would move them out of the staged order, and the
1.8 GB one is an environment the owner's own Hindsight would miss. Before moving
it, confirm no daemon runs from it:

```sh
ps -ax -o command= | grep 'uv/tools/hindsight-embed'
```

Mash's own daemon runs from `~/.mash/local/share/mash/hindsight` on
`~/.mash/.pg0`, so an empty result here is the expected, safe state.

## The loop — one group, one verification

Groups are ordered lowest-risk first. Quarantine one, then prove Mash still
works before moving on. Do not batch all groups into one command.

| # | Group | What leaves | Verify after |
|---|---|---|---|
| 1 | `1-launch` | `~/Applications/Herdr.app` | Mash still launches — **owner-run**, it ends this session |
| 2 | `2-watchers` | the two LaunchAgents | `launchctl list \| grep -E 'git-status-watch\|pr-watch-repo'` is empty (`com.luisalejandro.obsidian-bridge` is not part of this and stays); `herdr plugin log list` carries a `startup` entry running `poll.sh`; Mash panes still show git/PR badges |
| 3 | `3-helpers` | `~/dotfiles/bin` helpers | new dev / pi / reviewr tabs open; Telescope (cmd+p) opens |
| 4 | `4-plugins` | `~/dotfiles/plugins/herdr/*` | plugin manager (cmd+shift+x) lists plugins from Mash's bundle |
| 5 | `5-fonts` | MesloLGS NF from `~/Library/Fonts` | glyphs still render in Mash panes |
| 6 | `6-config` | `~/.config/{herdr,fresh}` plus, with `--include-shared`, `~/.config/{ghostty,pet,lazydocker,atuin}` | Herdr restarts in Mash and keeps its theme and keys — **owner-run**, the restart ends this session; `/Applications/Ghostty.app` now opens with stock defaults |
| 7 | `7-pi` | pi extensions, plus the skills and agents Mash carries | `pi` starts in a Mash pane; skills and agents are present. The count grows once the rebuilt app is installed, because it also carries the design-stack skills and agents; use `--groups` rather than a fixed number |
| 8 | `8-shell` | `~/.atuin` (with `--include-shared`) | the owner's own shell reports the missing `~/.atuin/bin/env` until `~/.zshrc` is edited; Mash panes are unaffected |

Two verifications cannot be done by an agent inside Mash. Group 1 asks whether
the app launches and group 6 whether Herdr restarts — both require quitting the
app the runbook is running in. Hand those two to the owner, or apply groups
1 and 6 last and let one relaunch cover both.

```sh
./scripts/port-check.sh --group 3-helpers --apply
```

Each run prints exactly what moved and where. Default quarantine location:
`~/Mash-retired-<timestamp>/`. Use `--quarantine DIR` to choose another.

**Groups 6 and 8 need `--include-shared`.** Group 6 holds `~/.config/ghostty`,
`~/.config/pet`, `~/.config/lazydocker` and `~/.config/atuin`; group 8 holds
`~/.atuin`. All five are reported as `SHARED` because the owner's own terminal
and shell read them too, so a plain `--apply` leaves them alone.

**The owner has decided to move them**, so the flag is expected rather than an
escalation. Add it explicitly:

```sh
./scripts/port-check.sh --group 6-config --apply --include-shared
./scripts/port-check.sh --group 8-shell  --apply --include-shared
```

The reason given was confusion between the owner's own Ghostty and Mash, which
share a theme (`Monokai Cursor`), a font (`MesloLGS NF`) and keybindings. Note
that the Ghostty config carries all three, not only the theme, so the owner's
Ghostty returns to stock defaults after this: no theme, default font, and none
of the 49 keybindings. Mash keeps its own copy under `~/.mash/config/ghostty/`
and is unaffected. If the owner only wanted the theme to differ, editing the
theme line in their own config was the smaller change — say so if they seem
surprised, since the quarantine is still on disk and reversible.

## Host programs

The groups above retire files in the home folder. This retires the Homebrew
packages that were installed for the setup Mash replaced. Mash carries its own
copy of each program below, so the host copy is redundant **for Mash**. The last
row is the exception, and the reason is in that row.

**Never run `brew uninstall` without the owner's explicit approval, one package
at a time.** This is the only part of this runbook that changes the machine
rather than the owner's files.

### Mash carries its own — candidates for removal

| Program | Mash's copy | Removable? |
|---|---|---|
| `lazydocker` | bundled, 0.25.2 | yes — the owner asked for this |
| `lazygit` | bundled, 0.65.1 | yes — the owner asked for this |
| `herdr` | bundled, 0.9.3 | yes — the personal Herdr is what this runbook retires |
| `fresh-editor` | Mash builds its own patched Fresh | yes — its config left in group 6 |
| `pet` | bundled | ask — only if the owner has no standalone use for it |
| `ghostty` (cask) | Mash nests its own | **no** — it is also the owner's own terminal |

```sh
# only after the owner approves, and only the names they name
brew uninstall lazydocker lazygit herdr fresh-editor
```

Verify Mash carries each one before removing it:

```sh
for t in lazydocker lazygit herdr fresh; do
  test -x "/Applications/Mash.app/Contents/Resources/bin/$t" && echo "bundled: $t"
done
```

`pet` is bundled too, if the owner decides to drop it.

### Mash relies on these — leave installed

Mash has no bundled replacement. `lib.sh` prepends `/opt/homebrew/bin` to every
pane's `PATH` for the first group below, and `~/.bun/bin` for the last:

- `git`, `gh`, `jq`, `fzf`, `fd`
- `bat`, `ripgrep`, `git-delta`, `eza`, `zoxide`
- `sentrux`
- `git-flow-next` — `mash-pr` and `mash-release` call `git flow`
- `gnupg`, `pinentry-mac`, `libfido2` — the owner's commits are signed
- `prettier`, `shfmt`, `latexindent`, `gopls`, `rust-analyzer`, `marksman`, `texlab`
- `bash-language-server`, `typescript-language-server`, `yaml-language-server`,
  `tailwindcss-language-server`, `vscode-langservers-extracted`, `python-lsp-server`
- `node@24` and `python@3.13`, because those servers' shebangs point at
  Homebrew's node and at the `python-lsp-server` formula's own interpreter
- `bun`, `bunx` — not a Homebrew formula: the bun installer put them in
  `~/.bun/bin`, which Mash reaches through its own `PATH` entry rather than
  through `/opt/homebrew/bin`
- `viu` — `plugins/image-popup/view.sh` draws the image `show_file` hands it,
  and prints `brew install viu` when it is missing. Mash does not bundle it, so
  the feature degrades on any machine without the formula.

Removing any of these does not stop Mash from starting. It breaks something
later and silently — a language server, a Telescope preview, or the git pager.

### Not needed by Mash either way

- `rust` — installed to build the old Herdr Rust plugins. Mash's own build
  downloads Rust 1.98.1 and Go 1.26.4 into a work directory, so neither is
  needed to build it. Keep `rust-analyzer`: it is a separate formula that Mash
  uses, and without the toolchain it simply cannot run `cargo check`.
- `go` — predates this work entirely.

### Verify after removing

Open the lazygit popup (`ctrl+shift+g`) once. The shipped Herdr config runs a
bare `exec lazygit`, so this is what confirms Mash's own copy still wins on the
pane `PATH`. Then re-run `./scripts/port-check.sh` read-only and confirm the
counts are unchanged: this section must not alter what the groups see.

## Stop conditions

Stop and report to the owner if:

- `codesign --verify --deep --strict /Applications/Mash.app` fails. The bundle
  grew files after signing, and every move below assumes the app is the
  artifact it claims to be.
- `UNVERIFIED` covers anything other than the three expected Hindsight paths
  described above.
- The `PORTED` count drops between the read-only run and the applicant run.
- Any `plugin_root` in `~/.mash/config/herdr/plugins.json` points outside
  `/Applications/Mash.app`. A plugin registered from a source checkout means
  the bundle is incomplete, and the same goes for any plugin whose `[[startup]]`
  section is missing from the registry — the watchers in group 2 are replaced by
  one such startup process.
- Any verification in the table above fails after a group is applied.
- Something in the quarantine folder turns out to be needed.

## Never touch

Left alone by design, and not listed as quarantine candidates:

- The Homebrew packages Mash borrows — git, gh, fzf, fd, bat, rg, jq, delta,
  eza, zoxide, sentrux, uv, gpg, and the language servers. Mash prepends
  `/opt/homebrew/bin` to every pane's `PATH`; removing those breaks Mash. See
  *Host programs* for the few packages in the same tree that are safe to remove.
- `~/.bun` — the bun installer's directory, not Homebrew's and not part of
  anything this runbook retires. `lib.sh` adds `~/.bun/bin` to every pane's
  `PATH`, so `bun` and `bunx` keep working afterwards. Do not quarantine.
- Xcode Command Line Tools, Docker Desktop, `/Applications/Ghostty.app`.
- `~/.gitconfig` and `~/.gitignore-global` — the owner's identity, not a
  component. Mash uses its own `~/.mash/config/git/config`.
- `~/.pi/agent/{sessions,missions,auth.json,trust.json,models*.json,run-history.jsonl,web-search.json}` — session history and credentials.
- `~/Development/{mash-programming-skills,maintainer-tools,mash-design-skills}`
  — upstreams. `packaging/carry.sh` hard-requires the first one to rebuild Mash.
- `~/Development/{rosey,second-brain}`, `~/.cursor` — unrelated.
- Ported, so *not* kept: the design stack (11 skills, 6 agents, `~/.config/mash`,
  `penpot-local`) and Hindsight (its config, the venv Mash builds for itself),
  once the rebuilt app is installed. Their entries move to `PORTED`/`SHARED`
  on their own.
- Still not ported, so genuinely kept: `~/.config/opencode` and `~/.opencode`
  (Mash ships no opencode), the `herdr` skill in `~/.pi/agent/skills/herdr` and
  `~/.agents/skills` (ships with Herdr, not Mash), the
  `mash-pattern-recognition-specialist` agent, `~/.local/bin/agent` (a Cursor
  CLI wrapper), and the reference docs in `~/dotfiles`.
- `~/.local/bin/cua-driver` is a **HOST** dependency, not a leftover: the
  wizard installs it and Mash's bundled `mcp.json` calls it. Never quarantine
  it.
- `~/.local/bin/herdr-reviewr` is a symlink into
  `~/.config/herdr/plugins/github/persiyanov.reviewr-…/bin/herdr-reviewr`, so it
  dangles once group 6 moves that directory. `port-check.sh` does not list it —
  it only walks the paths in its plan. Harmless, since Mash nests its own
  reviewr, but remove the dead link by hand if a broken entry on `PATH` bothers
  you.

## Outstanding owner actions

These are not script work. Report them as open items.

1. **No secret rotation is required here.** An earlier draft asked for it on
   the grounds that a GitHub PAT sat in `~/.pi/agent/settings.json` and an Apple
   app-specific password in `mash/.env`. Both grounds are gone:
   `settings.json` holds no token at all (it lists packages, theme, provider
   and tools), and a secret in a gitignored `.env` is the normal 12-factor way
   to keep credentials out of a repository — the file has never been tracked
   and the value appears in no blob of this repo's history. Nothing to do.
   Note that `~/.pi/agent/auth.json` does hold a live Google API key in the
   clear. It is the owner's own data, this runbook never touches it (see
   *Never touch*), so it is neither a blocker nor something this task changes.
2. **`~/.zshrc` now sources a quarantined atuin, in two places.** The owner
   decided to move `~/.atuin`, so line 113 (`. "$HOME/.atuin/bin/env"`) is
   broken by the time group 8 finishes, and so is line 115
   (`eval "$(atuin init zsh)"`), because `atuin` itself lives under `~/.atuin`.
   Fix both by hand; the script never touches `~/.zshrc`. Mash panes are
   unaffected, because they run with `ZDOTDIR=~/.mash/config/zsh`.
3. **The owner's own Ghostty returns to stock defaults** after group 6: no
   `Monokai Cursor` theme, default font, and none of the 49 keybindings, because
   all of that lived in the single config file that moved. Mash is unaffected.
   If that was not the intent, restore just the config file from quarantine and
   change its `theme` line instead.
4. **Mash's git identity is set by the wizard.** The first launch asks for a
   name and email, prefilled from the machine's own `~/.gitconfig`, and writes
   them into `~/.mash/config/git/config`. Leaving both empty is allowed and
   means commits made in Mash stay unattributed. Confirm what landed:

   ```sh
   git config --file ~/.mash/config/git/config --get user.name
   git config --file ~/.mash/config/git/config --get user.email
   ```

5. **Group 7 moves a `settings.json` whose package list is not Mash's — and
   that is settled.** `port-check.sh` calls it `PORTED` because a Mash-side
   settings file exists, which is a filename check rather than an equivalence
   check. The only difference that mattered was `npm:pi-mcp-adapter` in the
   personal file: `pi-mcp-adapter` is discarded, because pi now reads MCP
   servers natively from `~/.mash/pi/agent/mcp.json`, which Mash already ships
   populated (`context7`, `sentrux`, `cua-driver`, …). Nothing has to be added
   to Mash and nothing has to be preserved from the personal file. `~/.config/mcp`
   stays `UNPORTED` and untouched — it holds only `{}`.

## Rollback

Everything moved is still on disk under the quarantine folder. Most likely
restores, in order of likelihood:

```sh
# the owner's own terminal config, if the theme move was a mistake
cp -a ~/Mash-retired-<ts>/.config/ghostty ~/.config/
# one helper script
cp -a ~/Mash-retired-<ts>/dotfiles/bin/herdr-fresh-pane ~/dotfiles/bin/
```

Group 2 is the only irreversible-feeling step: a quarantined LaunchAgent stays
unloaded until `launchctl bootstrap gui/$(id -u) <plist>` is run again. Mash
does not need it.
