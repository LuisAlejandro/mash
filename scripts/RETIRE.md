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

## Preconditions — confirm all five, stop if any fails

1. **Mash is installed and has been used.**
   `test -d /Applications/Mash.app && test -d ~/.mash`
2. **This shell is inside Mash, not the personal setup.**
   `echo "$HERDR_SOCKET_PATH"` must contain `/.mash/run/`.
   If it contains `/.config/herdr`, stop — `port-check.sh` refuses anyway.
3. **The personal Herdr and its Ghostty windows are quit.** Otherwise moving
   `~/.config/herdr` pulls the config out from under a live server. Ask the
   owner to close them, then confirm `pgrep -f /opt/homebrew/bin/herdr` is
   empty.
4. **A backup exists.** Time Machine snapshot, or a `tar` of `~/dotfiles`,
   `~/.pi`, `~/.agents` and `~/.config`. Ask the owner to confirm.
5. **Two secrets are revoked** (see *Outstanding owner actions* below). The run
   is safe either way, but do not report the task as complete until they are.

## Read-only first

```sh
cd /Volumes/Documents/Software/mash
./scripts/port-check.sh              # full plan
./scripts/port-check.sh --groups     # staging groups and sizes
```

Report the summary to the owner, then continue. An `UNVERIFIED` entry has no Mash
counterpart on disk and must not be touched. Stop and ask if one is not
accounted for below.

Expected `UNVERIFIED` before Mash is reinstalled: the three Hindsight paths
(`~/.local/bin/hindsight`, `~/.local/bin/hindsight-embed`,
`~/.local/share/uv/tools/hindsight-embed`). They resolve to `SHARED` on their own
once the rebuilt app is installed, because their evidence is the config Mash
ships. Anything else `UNVERIFIED` is a real gap.

## The loop — one group, one verification

Groups are ordered lowest-risk first. Quarantine one, then prove Mash still
works before moving on. Do not batch all groups into one command.

| # | Group | What leaves | Verify after |
|---|---|---|---|
| 1 | `1-launch` | `~/Applications/Herdr.app` | Mash still launches |
| 2 | `2-watchers` | the two LaunchAgents | `launchctl list \| grep luisalejandro` is empty; Mash panes still show git/PR badges |
| 3 | `3-helpers` | `~/dotfiles/bin` helpers | new dev / pi / reviewr tabs open; Telescope (cmd+p) opens |
| 4 | `4-plugins` | `~/dotfiles/plugins/herdr/*` | plugin manager (cmd+shift+x) lists plugins from Mash's bundle |
| 5 | `5-fonts` | MesloLGS NF from `~/Library/Fonts` | glyphs still render in Mash panes |
| 6 | `6-config` | `~/.config/{herdr,fresh}` plus, with `--include-shared`, `~/.config/{ghostty,pet,lazydocker,atuin}` | Herdr restarts in Mash and keeps its theme and keys; `/Applications/Ghostty.app` now opens with stock defaults |
| 7 | `7-pi` | pi extensions, plus the skills and agents Mash carries | `pi` starts in a Mash pane; skills and agents are present. The count grows once the rebuilt app is installed, because it also carries the design-stack skills and agents; use `--groups` rather than a fixed number |
| 8 | `8-shell` | `~/.atuin` (with `--include-shared`) | the owner's own shell reports the missing `~/.atuin/bin/env` until `~/.zshrc` is edited; Mash panes are unaffected |

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

Mash has no bundled replacement, and `lib.sh` prepends `/opt/homebrew/bin` to
every pane's `PATH`:

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

- `UNVERIFIED` covers anything other than the three expected Hindsight paths
  described above.
- The `PORTED` count drops between the read-only run and the applicant run.
- Any verification in the table above fails after a group is applied.
- Something in the quarantine folder turns out to be needed.

## Never touch

Left alone by design, and not listed as quarantine candidates:

- The Homebrew packages Mash borrows — git, gh, fzf, fd, bat, rg, jq, delta,
  eza, zoxide, sentrux, uv, bun, gpg, and the language servers. Mash prepends
  `/opt/homebrew/bin` to every pane's `PATH`; removing those breaks Mash. See
  *Host programs* for the few packages in the same tree that are safe to remove.
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

## Outstanding owner actions

These are not script work. Report them as open items.

1. **Revoke two live secrets.** A GitHub PAT is stored in plaintext in
   `~/.pi/agent/settings.json`; an Apple app-specific password is in
   `/Volumes/Documents/Software/mash/.env`. Both must be revoked at the source
   regardless of what happens to the files.
2. **`~/.zshrc` now sources a quarantined atuin.** The owner decided to move
   `~/.atuin`, so line 113 (`. "$HOME/.atuin/bin/env"`) is broken by the time
   group 8 finishes. Edit by hand; the script never touches `~/.zshrc`. Mash
   panes are unaffected, because they run with `ZDOTDIR=~/.mash/config/zsh`.
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
