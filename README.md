<img align="right" height="100" src="https://cloud.githubusercontent.com/assets/324683/14374725/0a483732-fd23-11e5-9b56-b0e280b20760.png">

# Mash

> An open source alternative to Sublime Text based on vim and urxvt

Current version: 0.1a1

**Attention: this in an alpha release. Don't use it on production environments as
you will probably experience bugs.**

*Mash* is a group of Vim plugins and configurations designed to resemble
the appeareance and functionality of Sublime Text. Its main purpose is to make
users from Sublime to be more comfortable using Vim and perhaps encourage them
to switch IDE environments in the future.

*Mash* needs a graphical interface to work because we need urxvt for
proper key shorcuts, but in the future this might change. This means it won't
work on server environments, sorry. *Mash* ships as a separate binary
and does not integrate with Vim (yet). See [Usage](#usage) for details.

Also, for now we are only supporting Debian-based systems on the installation
script, but you might want to try installing on a different OS and tell us how
you you did it, or submit a
[greatly appreciated PR](https://github.com/CollageLabs/mash/pulls).

![Screenshot](https://cloud.githubusercontent.com/assets/324683/18112460/b9c94b3a-6ef5-11e6-9d11-43df8c950f87.png "Screenshot")

## Features

* Sublime Text key shorcuts and functionality. 
* Syntax highlighting of popular languages.
* Integrated linting and autocomplete for Python, Perl, Ruby, Javascript, Go, Haskell & more.

## Known bugs - work in progess

* See the [issues section](https://github.com/CollageLabs/mash/issues)
for more information.

## Installation

First make sure that you have `sudo` and `curl` installed. If not, you can install it by opening
a root terminal and typing the following command:

```bash
apt-get install sudo curl
```

Then, open a user terminal and start the installation process with the following command.
This will take a few minutes to complete depending on your internet connection speed.

```bash
bash <(curl -fLo- https://raw.githubusercontent.com/CollageLabs/mash/develop/install.sh)
```

## Usage

You can click on Subliminal Vim's icon on the menu or execute it on console by
typing `mash`.

You can use the mouse to select documents on the panel, single click opens them.
You cannot select tabs by clicking on them (yet), you'll have to use key shorcuts
for that (Alt+1, Alt+2, ...).

### Common key shortcuts

| Shortcut | Function |
| --- | --- |
| `Ctrl-o` | Open document |
| `Ctrl-s` | Save document |
| `Ctrl-c` | Copy a block or single line of code |
| `Ctrl-x` | Cut a block or single line of code |
| `Ctrl-v` | Paste a block or single line of code |
| `Ctrl-z` | Undo last action |
| `Ctrl-y` | Redo last action |
| `Ctrl-w` | Close current file |
| `Ctrl-Shift-7` | Comment a block or single line of code |
| `Ctrl-Shift-Up` | Move a block or single line up |
| `Ctrl-Shift-Down` | Move a block or single line down |

## License

Copyright (C) 2016 Mash Developers

Please refer to CONTRIBUTORS.md for a complete list of Copyright holders.

Mash is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

Mash is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see http://www.gnu.org/licenses/.

