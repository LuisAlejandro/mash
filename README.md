### File explorer panel

[![Join the chat at https://gitter.im/LuisAlejandro/subliminal-vim](https://badges.gitter.im/LuisAlejandro/subliminal-vim.svg)](https://gitter.im/LuisAlejandro/subliminal-vim?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

The file explorer panel is powered by the NERDTree plugin. You can use it with the following shorcuts.





# Introduction #
* C-a == Ctrl-a 
* M-a == Alt-a

# General #
```
:q        close
:w        write/saves
:wa[!]    write/save all windows [force]
:wq       write/save and close
:x        save and quit, same as wq
:q!       force close if file has changed and not save changes
```

```
v        Enter visual mode for selection of LINES
C-v      Enter visual mode for selection of BLOCKS
y        Yank/copy selected region
yy       Yank/copy entire line
"<reg>y  Yank/copy marked region into register <reg> (register from a-z)
c        Cut selection
p        Paste yanked content
"<reg>p  Paste yanked content in register <reg> (from a-z)
P        Paste yanked content BEFORE
```

```
u        Undo
C-r      Redo
```

```
:!<cmd>  Execute shell command <cmd>
C-z      send vim to background (fg brings it to front again)
```

### Windows ####
```
C-ws     Split current window horizontally (alternative :split)
C-wv     Split current window vertically (alternative :vsplit)
C-ww     Jump to the next window
C-wARROW Jump to window left/right/top/bottom (arrow keys) to the current
C-w#<    Shrink/resize current window from the right by # (default 1) 
C-w#>    Increase/resize current window to the right by # (default 1) 
```

### Entering insert mode ###
```
a        Append text after the cursor
A        Append text at the end of the line
i        Insert text before the cursor
I        Insert text before the first non-blank in the line
o        Begin a new line BELOW the cursor and insert text
O        Begin a new line ABOVE the cursor and insert text 
s        Erase the current letter under the cursor, set insert-mode
S        Erase the whole line, set insert-mode
cc       Delete the current line, set insert-mode
cw       Delete word, set insert-mode
dd       Delete line under curser
```

### Recording ###
Vim has 26 registers (a-z), select the one you want to record in, see below. Exit Record mode with ESC
```
q[a-z]   Start recording, everything will be recorded including movement actions.
@[a-z]   Execute the recorded actions.    
```


### Spell checking ###
See vimcast #19 as an introduction: http://vimcasts.org/episodes/spell-checking/

Assuming that you have the following in .vimrc:
```
nnoremap <silent> <leader>s :set spell!<cr>
```

```
<leader>s Toggle Spelling
]s       Next spelling mistake
[s       Previous spelling mistake
z=       Give Suggestions (prepent 1, use first suggestions automatically)
zg       Add misspelled to spellfile
zug      Remove word from spellfile
```
see http://vimdoc.sourceforge.net/htmldoc/spell.html

# Navigation #

_essential_
```
h        cursor left
j        cursor down
l        cursor right
k        cursor up
```

```
H        Jump to TOP of screen
M        Jump to MIDDLE of screen
L        Jump to BOTTOM of screen
C-b      Move back one full screen (page up)
C-f      Move forward one full screen (page down)
C-d      Move forward 1/2 screen; half page down
C-u      Move back (up) 1/2 screen; half page up
```

```
w        jump by start of words (punctuation considered words)
e        jump to end of words (punctuation considered words)
b        jump backward by words (punctuation considered words)
0 (zero) start of line
^        first non-blank character of line
$        end of line
G        bottom of file
gg       top of file
```


_good to know_
```
E        jump to end of words (no punctuation)
W        jump by words (spaces separate words)
B        jump backward by words (no punctuation)
#G       goto line #
#gg      goto line #
```

# Search, jump #
consider consulting `:help [` and `:help g`

```
*        search for word under cursor (forward) and highlight occurrence (see incsearch, hlsearch below)
%        jump from open/close ( / #if / ( / { to corresponding ) / #endif / } 
[{       jump to start of current code block
]}       jump to end of current code block
gd       jump to var declaration (see incsearch, hlsearch below)
f<c>     Find char <c> from current cursor position -- forwards
F<c>     Find char <c> from current cursor position -- backwards
,        Repeat previous f<c> or F<c> in opposite direction
;        Repeat previous f<c> or F<c> in same direction
'.       jump back to last edited line.
g;       jump back to last edited position.
[m       jump to start of funtion body
[i       show first declartion/use of the word under cursor
[I       show all occurrences of word under cursor in current file
[/       cursor to N previous start of a C comment
```

### vimgrep and quickfix list ###
built-in grep, vimgrep uses vim's quickfix list. see vimcasts#44 for introduction: http://vimcasts.org/episodes/search-multiple-files-with-vimgrep/
```
:vimgrep /<regex>/g %        Search for <regex> with multiple occasions per line (g) 
                             in current file (%)
:vimgrep /<C-r>// %          On the command line, <C-r>/ (that is: CTRL-R followed by /) 
                             will insert the last search pattern.  
:vimgrep /<a>/g <filelist>   Search in the given files (<filelist>) 
:vimgrep /<a>/g *.cc         Search in all *.cc files current directory
:vimgrep /<a>/g **/*.cc      Search in all *.cc files in every sub-directory (recursively) 
:vimgrep /<a>/g `find . -type f`     
                             Search in all files that are returns by the backtick command.

:vim     short for :vimgrep

:cnext   Jump to next record/match in quickfix list
:cprev   Jump to previous record/match in quickfix list
```
Unimpaired plugin (https://github.com/tpope/vim-unimpaired) provides the following mappings:
```
[q       see :cprev
]q       see :cnext
[Q       see :cfirst
]Q       see :clast
```
see also: http://usevim.com/2012/08/24/vim101-quickfix/ and http://vimdoc.sourceforge.net/htmldoc/quickfix.html

## Marks ##
Mark a position in a buffer and jump back to it. see also http://vim.wikia.com/wiki/Using_marks 
```
ma       set mark a at current cursor location
'a       jump to line of mark a (first non-blank character in line)
`a       jump to position (line and column) of mark a
d'a      delete from current line to line of mark a
d`a      delete from current cursor position to position of mark a
c'a      change text from current line to line of mark a
y`a      yank text to unnamed buffer from cursor to position of mark a
:marks   list all the current marks
:marks aB list marks a, B
```
(text is copied from link above)

# Editing #
```
x        Delete char UNDER cursor
X        Delete char BEFORE cursor
#x       Delete the next # chars. starting from char under cursor
dw       Delete next word
dW       Delete UP TO the next word
d^       Delete up unto the beginning of the line
d$       Delete until end of the line 
D        See d$, delete until end of the line  
dd       Delete whole line
dib      Delete contents in parenthesis '(' ')' block (e.g. function args)
diB      Delete inner '{' '}' block
daB      Delete a '{' '}' block
das      Delete a senctence
diw      Delete word under cursor
df<c>    Delete until next occurence of <c> (char) found (including <c>) [in single line]
dt<c>    Delete until next occurence of <c> (char) found (without <c>!!!) [in single line]

ciw      Change word under cursor 
ciB      Change inner '{' '}' block
cf<c>    See "df<c>" but change instead of delete
ct<c>    See "dt<c>" but change instead of delete

#J       Merge # number of lines together
```

```
gq       (in visual-mode) format selected text according to line-width
gqq      format current line according to line-width
#gqq     format next #-lines  
```

```
C-n      Keyword completion
Tab      Keyword completion (SuperTab plugin)
r<c>     Replace char <c>
#r<c>    Replace follow # chars with <c>, : csock, cursor on s, 3re ceeek
```

```
:s/xxx/yyy/    Replace xxx with yyy at the first occurrence
:s/xxx/yyy/g   Replace xxx with yyy first occurrence, global (whole sentence)
:s/xxx/yyy/gc  Replace xxx with yyy global with confirm
:%s/xxx/yyy/g  Replace xxx with yyy global in the whole file
```

```
u        Convert selection (visual mode) to lowercase
U        Convert selection (visual mode) to uppercase
```

```
:g/^#/d  Delete all lines that begins with #
:g/^$/d  Delete all lines that are empty
```
# Misc #

```
ga       Show ASCII of char under cursor
```

# Key sequences #
#### Replace a word in a number of occurrences with 'bar'; use word under cursor (`*` or `/foo`) ####
`* cw bar ESC n .` 
```
*     word under cursor 'foo'
cw    change word (enter insert mode)
bar   typed new word 'bar'
ESC   exit insert mode
n     next occurrence
.     repeat previous command 
```

#### Insert 3 times "Help!": `Help! Help! Help! ` ####
`3i Help!_ ESC`

#### Insert previously yanked text in line after current ####
`oESCp` 

#### Search for selected text ####
`<select> y / C-r0` 
```
<select> Select text in VISUAL mode (v)
y        Yank selection
/        Search for
C-r0     Press Ctrl-R and 0 to paste in
```

#### Comment out selection ####
`C-v <select> # ESC ESC`
```
C-v   Enter VISUAL block mode
<sel> Select lines
#     Comment char for programming language (perl, python, bash, etc)
ESC   Exit
ESC   Completes adding comment char for previous selected block
```

# Abbreviations #
auto correction of frequently misspelled words.

```
:abbr Lunix Linux
:abbr accross across
:abbr hte the
```

# Configuration #
* If you set the **incsearch** option, Vim will show the first match for the pattern, while you are still typing it. This quickly shows a typo in the pattern.
* If you set the __hlsearch__ option, Vim will highlight all matches for the pattern with a yellow background. This gives a quick overview of where the search command will take you. In program code it can show where a variable is used. You don't even have to move the cursor to see the matches.

# NERD-tree #
https://github.com/scrooloose/nerdtree/blob/master/doc/NERD_tree.txt
```
F3       Toogle NERD-Tree visible 
```

# ctrlp.vim #
https://github.com/kien/ctrlp.vim
```
C-p      Open ctrlp window (alternative :CtrlP)
:CtrlP d Open CtrlP with specific d = directory
```

```
C-b      Change mode: mru (most recent used) | buffers | files
```

# Formating #
Use `gq` (see Editing section) for formating lines according to configured line-width. 
For C++ formating using clang-format see https://github.com/rhysd/vim-clang-format

# Links #
## Cheat sheets ##
* http://www.worldtimzone.com/res/vi.html
* http://www.fprintf.net/vimCheatSheet.html
* https://wiki.archlinux.org/index.php/Vim
* http://www.fprintf.net/vimCheatSheet.html
* [Yet Another Vim Cheat Sheet](http://rtorruellas.com/vim-cheat-sheet/)

## Articles ##
* Seven habits of effective text editing: http://www.moolenaar.net/habits.html
* Vim After 11 Years: http://statico.github.com/vim.html
* Coming Home to Vim: http://stevelosh.com/blog/2010/09/coming-home-to-vim 

## tipps and tricks ##
* [vimcasts.org](http://vimcasts.org/) Video-casts on vim
* [usevim.com](http://usevim.com/) Plugin introductions and useful tipps
* [vimregex.com](http://vimregex.com/) Infos about vims regex engine 
* Productive vim shortcuts http://stackoverflow.com/questions/1218390/what-is-your-most-productive-shortcut-with-vim 
* 100 Vim commands every programmer should know http://www.catswhocode.com/blog/100-vim-commands-every-programmer-should-know
* [VimGenius](http://vimgenius.com/) Interactive vim lesson, with some muscle learn potential
* [Best of VimTips](http://zzapper.co.uk/vimtips.html) zzapper 15 Years of Vi + 8+ years of Vim and still learning 
* http://rayninfo.co.uk/vimtips.html
* Use ag (silver searcher) as an indexer for Ctrl-P; and py-matcher for ctrl-p matching function: http://blog.patspam.com/2014/super-fast-ctrlp
* [Command-T authors cheatsheet](https://wincent.com/wiki/Vim_cheatsheet)
* https://takac.github.io/2013/01/30/vim-grammar/


## Plugins ##
* NERDTree
* NERDCommenter
* Ctrl-P
* easytags
* unimpard
* supertab
* tagbar
* omnicomplete (C++)

## Themes ##
* zenburn
* tango

## Color column ##
* activate colorcolumn: http://stackoverflow.com/questions/1919028/how-to-show-vertical-line-to-wrap-the-line-in-vim
* set color: http://choorucode.wordpress.com/2011/07/29/vim-set-color-of-colorcolumn/

```
:set colorcolumn=81
highlight ColorColumn ctermbg=8
```


## Vim - What's included?

A list of some of the most useful commands that YADR provides in vim are
included below. This is not a comprehensive list. To get deeper knowledge,
practice a few of these every day, and then start looking into the lists
of plugins above to learn more.

#### Navigation

 * `Ctrl-6` - move between buffers
 * `,z` - go to previous buffer (:bp)
 * `,x` - go to next buffer (:bn)
 * `Cmd-j` and `Cmd-k` to move up and down roughly by functions (`Alt` in Linux)
 * `Ctrl-o` - Old cursor position - this is a standard mapping but very useful, so included here
 * `Ctrl-i` - opposite of Ctrl-O (again, this is standard)

#### NERDTree

 *


#### Search/Code Navigation

 * `,f` - instantly Find definition of class (must have exuberant ctags installed)
 * `,F` - same as `,f` but in a vertical split
 * `,gf` or `Ctrl-f` - same as vim normal gf (go to file), but in a vertical split (works with file.rb:123 line numbers also)
 * `gF` - standard vim mapping, here for completeness (go to file at line number)
 * `K` - Search the current word under the cursor and show results in quickfix window
 * `,K` - Grep the current word up to next exclamation point (useful for ruby foo! methods)
 * `Cmd-*` - highlight all occurrences of current word (similar to regular `*` except doesn't move)
 * `,hl` - toggle search highlight on and off
 * `,gg` or `,ag` - Grep command line, type between quotes. Uses Ag Silver Searcher.
 * `,gd` - Grep def (greps for 'def [function name]') when cursor is over the function name
 * `,gcf` - Grep Current File to find references to the current file
 * `//` - clear the search
 * `,,w` (alias `,<esc>`) or `,,b` (alias `,<shift-esc>`) - EasyMotion, a vimperator style tool that highlights jump-points on the screen and lets you type to get there.
 * `,mc` - mark this word for MultiCursor (like sublime). Use `Ctrl-n` (next), `Ctrl-p` (prev), `Ctrl-x`(skip) to add more cursors, then do normal vim things like edit the word.
 * `gK` - Opens the documentation for the word under the cursor.
 * Spacebar - Sneak - type two characters to move there in a line. Kind of like vim's `f` but more accurate.

#### File Navigation

 * `,t` - CtrlP fuzzy file selector
 * `,b` - CtrlP buffer selector - great for jumping to a file you already have open
 * `Cmd-Shift-M` - jump to method - CtrlP tag search within current buffer
 * `,jm` jump to models. Other `,j` mappings: `,jc` for controllers, `,jh` for helpers, etc. If you think of a concept and a letter, we've got you covered.
 * `Cmd-Shift-N` - NERDTree toggle (`Alt` in Linux)
 * `Ctrl-\` - Show current file in NERDTree
 * `Cmd-Shift-P` - Clear CtrlP cache

#### Better keystrokes for common editing commands

 * Ctrl-Space to autocomplete. Tab for snipmate snippets.
 * `,#` `,"` `,'` `,]` `,)` `,}` to surround a word in these common wrappers. the # does #{ruby interpolation}. works in visual mode (thanks @cj). Normally these are done with something like `ysw#`
 * `Cmd-'`, `Cmd-"`, `Cmd-]`, `Cmd-)`, etc to change content inside those surrounding marks. You don't have to be inside them (`Alt` in Linux)
 * `,.` to go to last edit location (same as `'.`) because the apostrophe is hard on the pinky
 * `,ci` to change inside any set of quotes/brackets/etc

#### Tabs, Windows, Splits

 * Use `Cmd-1` thru `Cmd-9` to switch to a specific tab number (like iTerm and Chrome) - and tabs have been set up to show numbers (`Alt` in Linux)
 * `Ctrl-h,l,j,k` - to move left, right, down, up between splits. This also works between vim and tmux splits thanks to `vim-tmux-navigator`.
 * `Q` - Intelligent Window Killer. Close window `wincmd c` if there are multiple windows to same buffer, or kill the buffer `bwipeout` if this is the last window into it.
 * `vv` - vertical split (`Ctrl-w,v`)
 * `ss` - horizontal split (`Ctrl-w,s`)
 * `,qo` - open quickfix window (this is where output from Grep goes)
 * `,qc` - close quickfix

#### Utility

 * `Ctrl-p` after pasting - Use `p` to paste and `Ctrl-p` to cycle through previous pastes. Provided by YankRing.
 * `,yr` - view the yankring - a list of your previous copy commands. also you can paste and hit `ctrl-p` for cycling through previous copy commands
 * `crs`, `crc`, `cru` via abolish.vim, coerce to snake_case, camelCase, and UPPERCASE. There are more `:help abolish`
 * `:NR` - NarrowRgn - use this on a bit of selected text to create a new split with just that text. Do some work on it, then :wq it to get the results back.
 * `,ig` - toggle visual indentation guides
 * `,cf` - Copy Filename of current file (full path) into system (not vi) paste buffer
 * `,cn` - Copy Filename of current file (name only, no path)
 * `,yw` - yank a word from anywhere within the word (so you don't have to go to the beginning of it)
 * `,ow` - overwrite a word with whatever is in your yank buffer - you can be anywhere on the word. saves having to visually select it
 * `,ocf` - open changed files (stolen from @garybernhardt). open all files with git changes in splits
 * `,w` - strip trailing whitespaces
 * `sj` - split a line such as a hash {:foo => {:bar => :baz}} into a multiline hash (j = down)
 * `sk` - unsplit a link (k = up)
 * `,he` - Html Escape
 * `,hu` - Html Unescape
 * `,hp` - Html Preview (open in Safari)
 * `Cmd-Shift-A` - align things (type a character/expression to align by, works in visual mode or by itself) (`Alt` in Linux)
 * `:ColorToggle` - turn on #abc123 color highlighting (useful for css)
 * `:Gitv` - Git log browsers
 * `,hi` - show current Highlight group. if you don't like the color of something, use this, then use `hi! link [groupname] [anothergroupname]` in your vimrc.after to remap the color. You can see available colors using `:hi`
 * `,gt` - Go Tidy - tidy up your html code (works on a visual selection)
 * `:Wrap` - wrap long lines (e.g. when editing markdown files)
 * `Cmd-/` - toggle comments (usually gcc from tComment) (`Alt` in Linux)
 * `gcp` (comment a paragraph)

#### Rails & Ruby

 * `,vv` and `,cc` to switch between view and controller - these are maps to :Rcontroller and :Rview. Explore the :R<Tab> family of commands for more fun from rails.vim!
 * `,rs` and `,rl` to run rspec or a spec line in iTerm (check iTerm window for results)
 * `,ss` and `,sl` for the same using `spring rspec` which makes your Rails specs faster by caching the Rails env (must have spring gem installed)
 * vim-ruby-refactoring - try `,rem`, `,rel` to extract methods or let statements
 * `Ctrl-s` - Open related spec in a split. Similar to :A and :AV from rails.vim but is also aware of the fast_spec dir and faster to type
 * `:Bopen [gem name]` to navigate to a gem (@tpope/vim-bundler)
 * `,gcp` - Grep Current Partial to find references to the current view partial
 * `,orb` - outer ruby block. takes you one level up from nested blocks (great for rspec)

#### Vim Dev

 * `,vc` - (Vim Command) copies the command under your cursor and executes it in vim. Great for testing single line changes to vimrc.
 * `,vr` - (Vim Reload) source current file as a vim file
