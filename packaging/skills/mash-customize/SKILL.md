---
name: mash-customize
description: Map of the Mash app for customization work — how its isolation works, where every config file lives, and how to install packages, extensions, skills, MCP servers and themes. Use when asked to customize, configure, extend, theme or change how Mash or Pi behaves inside Mash.
---

# Customizing Mash

Mash is an isolated application: a signed bundle plus a writable data folder.
Changing how it behaves means writing into the data folder, or changing Mash's
source repository (https://github.com/LuisAlejandro/mash) and rebuilding.

## The isolation model

`HOME` is **not** changed. Mash's panes keep the real home, so `~/.config`,
`$HOME/.pi` and `$HOME/.hindsight` still resolve to the user's own files.
Isolation is achieved only through environment variables, set by `mash_isolate`
in `Resources/bin/lib.sh`:

| Variable | Mash value |
|---|---|
| `XDG_CONFIG_HOME` | `~/.mash/config` |
| `XDG_STATE_HOME` | `~/.mash/local/state` |
| `XDG_DATA_HOME` | `~/.mash/local/share` |
| `XDG_CACHE_HOME` | `~/.mash/cache` |
| `PI_CODING_AGENT_DIR` | `~/.mash/pi/agent` |
| `GIT_CONFIG_GLOBAL` | `~/.mash/config/git/config` |
| `GH_CONFIG_DIR` | `~/.mash/config/gh` |
| `ZDOTDIR` | `~/.mash/config/zsh` |
| `STARSHIP_CONFIG` | `~/.mash/config/starship.toml` |
| `STARSHIP_CACHE` | `~/.mash/cache/starship` |
| `HERDR_CONFIG_PATH` | `~/.mash/config/herdr/config.toml` |
| `MASH_CONFIG_DIR` | `~/.mash/config/mash` |
| `MASH_FRESH_CONFIG_DIR` | `~/.mash/config/fresh` |

Two directories keep a leading dot because Hindsight names them itself:
`.hindsight` and `.pg0`, both directly under `~/.mash`. Everything else Mash
owns is flat.

**The bundle is read-only.** `Contents/` is signed with a Developer ID. Never
write into `/Applications/Mash.app`; anything that must change there is a repo
change plus a rebuild.

## Where things live

| Path | Contents |
|---|---|
| `~/.mash/pi/agent/` | Pi's agent directory: `settings.json`, `mcp.json`, `extensions/`, `skills/`, `agents/`, `scripts/`, `sessions/`, `auth.json`, `node_modules/` |
| `~/.mash/config/herdr/` | Herdr config and the plugin registry |
| `~/.mash/config/ghostty/` | Terminal config and themes |
| `~/.mash/config/fresh/` | Editor config, `init.ts`, plugins, themes |
| `~/.mash/config/git/config` | Mash's git config — pager, credential helper, `user.name`/`user.email` |
| `~/.mash/config/{pet,lazydocker,lazygit,atuin,zsh,bash,fish}/` | Those tools' configs |
| `~/.mash/config/starship.toml` | Shared prompt for bash, zsh and fish |
| `~/.mash/config/mash/` | Mash Programming Skills state: `references/`, `venvs/`, `hindsight-pin`, `hindsight-embed.env` |
| `~/.mash/local/share/mash/hindsight/` | Hindsight's virtualenv (~1.1 GB) |
| `~/.mash/setup/` | `state.txt`, `skills-choice`, `setup.log`, `hindsight-install.log` |
| `~/.mash/bin/` | Launcher-written helpers |

Files here persist. The launcher seeds a file only when it is missing
(`rsync --ignore-existing`), so local edits are never overwritten by a rebuild.
That also means a rebuild will not refresh a file you edited by hand — delete it
to pick up the new seed.

## Optional skills

The first-launch wizard defaults Programming Skills on. Uncheck it to omit its
skills, agents, and runtime payload from `~/.mash`; that also skips Hindsight
installation and startup. The choice is stored in
`~/.mash/setup/skills-choice`; upgrading never silently removes files from an
existing installation.

## Customizing Pi

Everything a user changes lives under `~/.mash/pi/agent/`: `settings.json`,
`mcp.json`, `extensions/`, `skills/`, `prompts/`, `themes/`, and installed
packages under `npm/`. Mash seeds a file only when it is missing, so edits
persist across rebuilds. Never write to `$HOME/.pi/agent`: that is the user's
own Pi, outside Mash.

### Packages

Two kinds, and they are added in different places.

**Installed by the user, at runtime.** In a Mash pane:

```sh
pi install npm:<name>
```

pi installs user packages under its agent directory, so this lands in
`~/.mash/pi/agent/npm/node_modules` and adds `npm:<name>` to Mash's
`settings.json`. It never writes into the signed bundle and never into
`$HOME/.pi/agent`. `pi remove npm:<name>` undoes it. npm caches downloads in
`~/.mash/cache/npm`. Restart pi to load a new package.

Mash sets both `PI_CODING_AGENT_DIR` and `PI_HOME` to `~/.mash/pi/agent`.
Packages that find their home through pi's `getAgentDir()` or through `PI_HOME`
are fully isolated. A package that hard-codes `$HOME/.pi/agent` cannot be, because
Mash never changes `HOME`; such a package would read and write the user's own
Pi, so check one before installing it.

A package resolves `@earendil-works/pi-coding-agent`, `pi-tui`, `pi-ai` and
`typebox` to Mash's bundled copies through pi's extension loader, so a package
that only peer-depends on pi installs small and runs against the pi Mash ships.

**Shipped with Mash for everyone, at build time.** Edit two files in the
repository and rebuild:

1. `packaging/build.sh` — the `npm install --global --prefix` list, with an
   exact version.
2. `packaging/defaults/pi/settings.json` — add `npm:<name>` to `packages`.

Mash ships `pi-subagents`, `pi-ask-user`, `@krfantasy/pi-monokai-pro`,
`pi-web-search` and `@earendil-works/pi-voice`. A package may bundle extensions,
skills, prompts and themes together.

`packaging/defaults/pi/node_modules` deliberately holds **one** package:
`typebox`, imported at runtime by `extensions/mash-orchestration.ts`. Node
resolves that import from the extension's directory upward, so it cannot reach
pi's own nested copy under `node/lib/node_modules/`. Everything else about pi
resolves from the global prefix.

### Extensions

An extension is a TypeScript module exporting a default factory that receives
`ExtensionAPI`. Drop it in `~/.mash/pi/agent/extensions/`:

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerCommand("hello", {
    description: "Show a greeting",
    handler: async (name, ctx) => ctx.ui.notify(`Hello, ${name || "world"}!`, "info"),
  });
}
```

For a one-off, `pi --extension ./hello.ts` loads it without installing. Extensions
run inside the Pi process with the same OS permissions, so they can read
credentials and session history — review third-party sources before installing.

Mash ships one: `extensions/mash-hindsight-daemon.ts`, the session warm-start.

### Skills, prompts and themes

- Skills: `~/.mash/pi/agent/skills/<name>/SKILL.md`, with optional `scripts/`,
  `references/` and `assets/` beside it. Pi advertises the name and description
  and loads the body only when relevant.
- Prompt templates: `~/.mash/pi/agent/prompts/*.md`, exposed as slash commands.
- Themes: `~/.mash/pi/agent/themes/*.json`.

### MCP servers

`~/.mash/pi/agent/mcp.json`. Mash ships `context7`, `sentrux`, `cua-driver`,
`agent-browser` and `chrome-devtools`. Keep a token out of this file if the bundle
might ever be shared — a build assertion rejects a `github` entry.

### Instructions

`~/.mash/pi/agent/AGENTS.md` and `APPEND_SYSTEM.md` hold Mash's always-on rules.
Both are generated by `packaging/carry.sh` (`mash_write_append_system`) and
seeded with `--ignore-existing`, so a runtime edit persists but is not
regenerable. Author permanent changes in the repo instead.

## Machine tools Mash borrows

Mash bundles its own terminal, agents and helpers, but it deliberately borrows
some tools from the host. `mash_isolate` in `Resources/bin/lib.sh` builds every
pane's `PATH` in three tiers: Mash's own directories first, then these host
directories (each only if it exists), then whatever was inherited:

| Directory | What Mash finds there |
|---|---|
| `~/.local/bin` | `cua-driver` and `agent-browser`, which Mash's wizard installs |
| `~/.bun/bin` | `bun` and `bunx` — the bun installer puts them here, not Homebrew |
| `/opt/homebrew/bin`, `/usr/local/bin` (and their `sbin`) | the Homebrew tools below |

From Homebrew: `git`, `gh`, `jq`, `fzf`, `fd`, `bat`, `rg`, `delta`, `eza`,
`zoxide`, `sentrux`, `git-flow-next`, `gpg`, plus the language servers and
formatters. `node@24` and `python@3.13` are needed because those servers'
shebangs point at Homebrew's interpreters.

Mash's own directories always come first, so a program Mash ships (pi, node,
python3, fresh, herdr, lazygit, ...) never resolves to a host copy of the same
name. A tool installed somewhere else — another version manager's directory,
say — is not on a pane's `PATH` unless it was already on the `PATH` Mash was
started with.

Removing a host tool does not stop Mash from starting; it breaks something later
and quietly.

## What needs a rebuild

Writing anywhere under these is a repo change, not a runtime one:

- anything in `Contents/` — binaries, plugins, the `defaults/` seeds
- `pins.txt` and the bundled versions
- Hindsight's venv and the plugin set

The flow is `bash packaging/build.sh`, then reinstall the app. The build refuses
to replace a running `Mash.app`.

## Pitfalls

- **Do not run `pi update`.** Mash pins one Pi inside the signed bundle;
  `PI_SKIP_VERSION_CHECK=1` disables the check for that reason. Update by
  changing the pin and rebuilding.
- **Do not write into `~/Applications` or the bundle.** Herdr's config and the
  plugin registry point inside `~/.mash`; the bundle is signed.
- **`.hindsight` and `.pg0` inside `~/.mash` cannot be renamed.** Both libraries
  hardcode a dot-prefixed directory under `Path.home()`, and `pg0` has no
  override at all. Changing `HOME` relocates the dot but never removes it.
- **Herdr's plugin registry stores absolute paths.** A registry linked during a
  build only resolves on the machine that built it, so the launcher re-links the
  carried plugins whenever the registry does not point at the running copy.
- **A config edit may need a restart.** Herdr reads `config.toml` at start;
  `herdr server reload-config` reapplies it without losing panes.
