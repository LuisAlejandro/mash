# Monokai for Fresh

The classic [Monokai](https://monokai.pro) color theme for the
[Fresh](https://getfresh.dev) terminal editor — the original Sublime / TextMate
palette on Monokai's signature `#272822` background.

## Install

In Fresh, press `Ctrl+P` and run **"Package: Install from URL"**, then paste:

```
https://github.com/lucasoskorep/fresh-monokai
```

Then `Ctrl+P` → **"Select Theme"** → **Monokai**.

Or set it directly in `~/.config/fresh/config.json`:

```jsonc
{ "theme": "https://github.com/lucasoskorep/fresh-monokai#Monokai" }
```

## Which Monokai is this?

The **original / classic Monokai** (Wimer Hazenberg's 2006 Sublime / TextMate
theme) — the same palette used by the Sublime and VS Code "Monokai" themes and
vim's `molokai`.

| Role | Hex |
|------|-----|
| background | `#272822` |
| foreground | `#F8F8F2` |
| selection | `#49483E` |
| current line | `#3E3D32` |
| comment | `#75715E` |
| keyword / operator | `#F92672` |
| string | `#E6DB74` |
| function | `#A6E22E` |
| type / class | `#66D9EF` |
| number / constant | `#AE81FF` |
| parameter / special var | `#FD971F` |

It is **not Monokai Pro** — that's the 2017 desaturated palette
(`#FF6188`, `#A9DC76`, `#FFD866`, `#FC9867`, `#AB9DF2`, `#78DCE8`).

## A note on syntax fidelity

Fresh maps all tree-sitter captures into **11 syntax slots**, so a couple of
distinctions the original Monokai makes are collapsed:

- `variable`, parameters and properties share one slot (plain `#F8F8F2`), so
  parameters don't get the classic italic orange.
- `constant` covers numbers, named constants and builtins (all `#AE81FF`).

Keywords, operators, strings, comments, functions and types are 1:1.

## Credits

Monokai color palette by Wimer Hazenberg.

## License

[GPL-3.0-or-later](LICENSE).
