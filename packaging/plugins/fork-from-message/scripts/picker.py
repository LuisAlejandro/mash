#!/usr/bin/env python3
"""Interactive user-message picker rendered inside a Herdr plugin pane.

Reads a JSON request from HERDR_FORK_REQUEST (a file path), renders the list,
and writes the chosen entry id to the request's "result" path. Exiting without a
choice writes nothing, which the launching action reads as a cancel.
"""

from __future__ import annotations

import json
import os
import select
import shutil
import sys
import termios
import tty
import unicodedata
from pathlib import Path


CLEAR = "\x1b[2J\x1b[H"
# Raw mode clears ONLCR, so a bare "\n" moves down without returning to the
# left margin and successive lines march rightward. Pair every newline with an
# explicit carriage return instead of relying on the terminal's output mode.
NL = "\r\n"
HIDE_CURSOR = "\x1b[?25l"
SHOW_CURSOR = "\x1b[?25h"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
REVERSE = "\x1b[7m"
RESET = "\x1b[0m"


# Long enough to survive a slow or synthetic key delivery, short enough that a
# bare Escape still feels immediate.
ESCAPE_SEQUENCE_TIMEOUT = 0.25

ARROW_KEYS = {"A": "up", "B": "down", "H": "home", "F": "end"}


def _read_byte(fd: int, timeout: float | None = None) -> str:
    """Read one byte from the raw descriptor, or "" when none arrives in time.

    Reads go through the descriptor rather than a buffered file object: a
    buffered read(1) pulls the whole escape sequence into Python's buffer, which
    leaves select() seeing an empty descriptor and makes an arrow key
    indistinguishable from a bare Escape.
    """
    if timeout is not None:
        ready, _, _ = select.select([fd], [], [], timeout)
        if not ready:
            return ""
    data = os.read(fd, 1)
    return data.decode("utf-8", "replace") if data else ""


def _read_key(fd: int) -> str:
    """Return a single logical keypress, decoding the arrow-key escapes.

    A bare Escape and the prefix of an arrow-key sequence share a first byte, so
    the follow-up bytes are only consumed when they actually arrive.
    """
    ch = _read_byte(fd)
    if ch != "\x1b":
        return ch
    if _read_byte(fd, ESCAPE_SEQUENCE_TIMEOUT) != "[":
        return "\x1b"
    final = _read_byte(fd, ESCAPE_SEQUENCE_TIMEOUT)
    return ARROW_KEYS.get(final, "")


def _clean(text: str) -> str:
    # Transcript text is untrusted terminal output; never render its escapes.
    return "".join(ch if ch.isprintable() or ch in "\n\t" else " " for ch in str(text)).expandtabs(4)


def _columns(ch: str) -> int:
    # ponytail: conservative codepoint width; overcounts joined emoji rather
    # than letting a preview wrap into another row. Use grapheme layout if needed.
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" or ch == "\ufe0f" else 1


def _prefix(text: str, width: int) -> str:
    used = 0
    for index, ch in enumerate(text):
        used += _columns(ch)
        if used > width:
            return text[:index]
    return text


def _visible(text: str, width: int) -> str:
    flat = " ".join(_clean(text).split())
    head = _prefix(flat, max(0, width))
    return head if head == flat else _prefix(flat, max(0, width - 1)) + "…"


def _preview(text: str, width: int, limit: int) -> list[str]:
    lines = []
    for line in _clean(text).split("\n"):
        if not line:
            lines.append("")
        while line:
            head = _prefix(line, width)
            lines.append(head or "…")
            line = line[max(1, len(head)):]
            if len(lines) > limit:
                break
        if len(lines) > limit:
            return lines[:limit - 1] + [_prefix(lines[limit - 1], width - 1) + "…"]
    return lines


def rendered_messages(messages):
    return [e for e in messages if e.get("visibility", "rendered") == "rendered"]


def render(messages, selected: int, offset: int, rows: int, title: str, notice: str = "") -> str:
    messages = rendered_messages(messages)
    size = shutil.get_terminal_size((100, 24))
    width = max(1, size.columns - 7)
    line_limit = min(3, max(1, (size.lines - 6) // max(1, rows)))
    out = [
        CLEAR,
        f" {BOLD}{_visible(title, size.columns - 2)}{RESET}{NL}",
        f" {DIM}{_visible('↑/↓ choose · Enter restart · Esc cancel', size.columns - 2)}{RESET}{NL}{NL}",
    ]
    for index in range(offset, min(len(messages), offset + rows)):
        entry = messages[index]
        text = entry["text"]
        if entry.get("forkable") is False:
            text = "[no earlier history] " + text
        for part, line in enumerate(_preview(text, width, line_limit)):
            prefix = f"{index + 1:>3}  " if part == 0 else "     "
            style = REVERSE if index == selected else DIM if entry.get("forkable") is False else ""
            out.append(f" {style}{prefix}{line}{RESET}{NL}")
    out.append(f" {DIM}{_visible(f'{selected + 1} of {len(messages)}', size.columns - 2)}{RESET}{NL}")
    out.append(f" {DIM}{_visible(notice or 'Restart before selection; draft stays unsent.', size.columns - 2)}{RESET}{NL}")
    return "".join(out)


def choose(messages, title: str) -> str | None:
    """Run the interactive loop on the controlling terminal."""
    messages = rendered_messages(messages)
    if not messages:
        return None
    tty_in = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    tty_out = open("/dev/tty", "w", encoding="utf-8", errors="replace")
    saved = termios.tcgetattr(tty_in)
    selected = len(messages) - 1  # Newest message, matching Pi's own default.
    offset = 0
    notice = ""
    try:
        tty.setraw(tty_in.fileno())
        tty_out.write(HIDE_CURSOR)
        while True:
            rows = max(1, (shutil.get_terminal_size((100, 24)).lines - 6) // 3)
            offset = min(max(offset, selected - rows + 1), selected)
            offset = max(0, min(offset, max(0, len(messages) - rows)))
            tty_out.write(render(messages, selected, offset, rows, title, notice))
            notice = ""
            tty_out.flush()
            key = _read_key(tty_in.fileno())
            if key in ("up", "k"):
                selected = (selected - 1) % len(messages)
            elif key in ("down", "j"):
                selected = (selected + 1) % len(messages)
            elif key == "home":
                selected = 0
            elif key == "end":
                selected = len(messages) - 1
            elif key in ("\r", "\n"):
                if messages[selected].get("forkable") is False:
                    notice = "No earlier history before this first user message."
                    continue
                return messages[selected]["id"]
            elif key in ("\x1b", "q", "\x03", "\x04", ""):
                return None
    finally:
        termios.tcsetattr(tty_in, termios.TCSADRAIN, saved)
        tty_out.write(SHOW_CURSOR + CLEAR)
        tty_out.flush()
        tty_in.close()
        tty_out.close()


def main() -> int:
    request_path = os.environ.get("HERDR_FORK_REQUEST")
    if not request_path:
        print("picker: HERDR_FORK_REQUEST is not set", file=sys.stderr)
        return 2
    try:
        request = json.loads(Path(request_path).read_text())
        messages = request["messages"]
        result_path = Path(request["result"])
        title = request.get("title", "Fork from Message")
    except (OSError, ValueError, KeyError) as exc:
        print(f"picker: unusable request: {exc}", file=sys.stderr)
        return 2

    chosen = choose(messages, title)
    if chosen is None:
        return 0
    temporary = result_path.with_suffix(".tmp")
    temporary.write_text(json.dumps({"id": chosen}))
    temporary.replace(result_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
