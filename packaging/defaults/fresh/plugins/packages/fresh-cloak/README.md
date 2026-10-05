# Fresh Cloak

Visually masks the values in `.env` assignments so they stay off your screen
during a screen share, a pairing session, or a recorded demo. Open a `.env`
file and recognized values render as a fixed placeholder instead of plaintext.
Masking is on by default.

## What this does not protect

**Read this before you rely on it. Fresh Cloak is a screen-sharing aid, not a
secret manager, and it does not make your secrets safe.**

Masking is *render-only*. Only the drawing of the line changes — the real text
is still in the buffer the whole time, completely untouched. That means:

- **Copy still copies the real value.** Copying a masked range puts the actual
  secret on your clipboard.
- **Search still searches the real text.** A search hit can find and show a
  value.
- **Other plugins can read it.** Anything running in Fresh reads the buffer,
  not the screen.
- **Process memory holds it.** The value is an ordinary string in memory.
- **The file on disk is unchanged.** It is plaintext `.env` before, during, and
  after, and anything that reads that file sees the real value.

The plugin never modifies buffer text, saved content, or undo history. It also
does not claim to protect against any of the above, and it cannot. Treat the
mask as protection against over-the-shoulder and screen-share exposure, and
nothing else.

## Requirements

- Fresh 0.5.1 or newer.

## Install

Fresh's package manager installs a plugin from a Git repository URL or a local
directory. Open the command palette (Quick Open — `Ctrl+P` on the default
keymap; your keymap may bind it differently), type `>`, and choose
**Package: Install from URL**. That command accepts either form:

```text
https://github.com/YOUR_USERNAME/fresh-cloak
```

```text
/absolute/path/to/fresh-cloak
```

Paths starting with `/`, `./`, `../`, or `~/` are recognized as local
directories and copied directly. **Package: Packages** browses and manages what
is installed, including updates and removal.

During development, validate the plugin without installing it:

```bash
fresh --check-plugin plugin.ts
```

That bundles the plugin and reports any syntax or resolution error.

## Usage

Supported files are masked the moment they are displayed — there is nothing to
turn it on. Keys, delimiters, quotes, comments, and whitespace all stay visible;
only the value is replaced.

### Turning it on and off

Two commands are registered. Bind either to a key in `~/.config/fresh/config.json`
(see below); both apply instantly, with no restart.

| Command | Scope |
| --- | --- |
| **Toggle .env value cloaking (setting)** | The whole plugin — every buffer. This is the on/off switch. |
| **Toggle .env value cloaking** | The active buffer only, leaving other `.env` buffers alone. |

The switch command writes the plugin's `enabled` setting, so it also appears in
the Settings UI under **Plugin Settings → fresh-cloak**, and turning it off from
either place takes effect immediately. Turning it off clears the masks already
on screen rather than waiting for the next edit.

That setting is the persistent default, read from your `config.json` at startup.
The key press changes the setting for the current session only — Fresh's plugin
API applies runtime setting changes in memory and does not rewrite your config
file, so an off press lasts until you restart Fresh. To make "off" the durable
default, set `enabled` to `false` in the config (or use the Settings UI, which
saves to disk):

```json
{
  "plugins": {
    "fresh-cloak": {
      "settings": {
        "enabled": false
      }
    }
  }
}
```

In short: the setting is the default that survives a restart, and the key is an
instant override within the session.

The plugin deliberately does one thing that may surprise you: when cloaking is
turned back on, every buffer starts masked again, including any buffer you had
revealed per-buffer beforehand. Keeping that per-buffer state across an off/on
cycle would leave a buffer showing plaintext while the switch reads "on",
which is precisely the confusion this plugin exists to prevent.

Two further things it deliberately does not do: it never reveals a value
because your cursor moved onto it or because you selected it, and it ships **no
default keyboard shortcut**, so installing it never overrides a key you already
use.

### Optional: bind your own key

If you want a shortcut, add one yourself in `~/.config/fresh/config.json`.
This is optional and entirely yours to choose — Fresh Cloak registers no
binding and will not overwrite this.

Note the key is `keybindings` (lowercase), the value is an array of binding
objects, and `action` is the handler name, not the human-readable command
title. Use `freshCloakToggleSetting` for the global on/off switch:

```json
{
  "keybindings": [
    {
      "key": "k",
      "modifiers": ["ctrl", "alt"],
      "action": "freshCloakToggleSetting",
      "when": "global"
    }
  ]
}
```

The per-buffer command uses the handler name `freshCloakToggle` if you would
rather bind that one, or bind both to different keys.

Pick a combination that is not already bound; check your keymap in the
keybinding editor first if you are unsure.

## Supported syntax

File names, matched on the base name of the path:

- `.env`
- `.env.local`, `.env.production`, and any other `.env.*`
- `development.env`, and any other `*.env`
- **Not** `.envrc`.

Within a recognized file, one line at a time:

- One-line `KEY=value` assignments.
- An optional `export ` prefix, and optional whitespace anywhere around it.
- Keys may contain letters, digits, `_`, `.`, and `-`, but may **not** begin
  with a digit, `.`, or `-`. So `DB.PASSWORD=` and `API-KEY=` are supported;
  `2KEY=` and `.KEY=` are not recognized and stay visible.
- Values in three forms: unquoted, single-quoted, or double-quoted. Surrounding
  whitespace is not part of the value; whitespace inside a quoted value is.
- A `#` outside quotes begins a comment, so the value ends there. A `#` inside
  either quote style is ordinary value content.
- An empty assignment (`EMPTY_VALUE=`, `EMPTY=""`) stays visibly empty. The
  plugin hides values, not the fact that a variable is unset.
- A backslash inside single quotes is literal text. Inside double quotes it
  escapes the next character.

Every masked value renders as the same fixed placeholder, `************`.
Because it never varies with the real value, the mask leaks neither its length
nor its character set.

## What stays visible

These forms are outside the supported one-line subset. Their values remain
**visible and unprotected**, and the plugin shows a single warning that does
not contain any of the value text:

- Multiline values, including quoted values that span lines.
- Line continuations — a line ending in an odd number of backslashes, `\`.
- An unclosed quote.
- Malformed assignments, such as trailing junk after a closing quote.

The warning reads:

> Fresh Cloak: some assignments use multiline or malformed syntax and are shown
> unmasked. See the plugin README for the supported subset.

If you see that warning, the affected lines are on screen as plaintext. Do not
assume they are hidden.

`examples/demo.env` in this repository demonstrates every case above.

## Uninstall / disable

Turn it off without uninstalling by binding **Toggle .env value cloaking
(setting)**, or by unchecking it under **Plugin Settings → fresh-cloak** in the
Settings UI.

Remove the package through **Package: Packages** in the command palette, or
disable it the way you manage any installed plugin. No manual cleanup is
needed: Fresh tracks the conceal ranges this plugin adds and clears them when
it unloads, so the masks disappear with it and your file is left untouched.

## License

GPL-2.0, matching Fresh itself.
