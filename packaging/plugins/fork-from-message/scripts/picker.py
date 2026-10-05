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


def _visible(text: str, width: int) -> str:
    flat = " ".join(str(text).split())
    if len(flat) <= width:
        return flat
    return flat[: max(0, width - 1)] + "…"


def render(messages, selected: int, offset: int, rows: int, title: str) -> str:
    width = max(20, shutil.get_terminal_size((100, 24)).columns - 4)
    out = [
        CLEAR,
        f" {BOLD}{title}{RESET}{NL}",
        f" {DIM}↑/↓ choose · Enter fork · Esc cancel{RESET}{NL}{NL}",
    ]
    for index in range(offset, min(len(messages), offset + rows)):
        entry = messages[index]
        label = _visible(entry["text"], width - 8)
        number = f"{index + 1:>3}"
        if index == selected:
            out.append(f" {REVERSE} {number} {label} {RESET}{NL}")
        else:
            out.append(f"  {DIM}{number}{RESET} {label}{NL}")
    if len(messages) > rows:
        out.append(f"{NL} {DIM}{selected + 1} of {len(messages)}{RESET}{NL}")
    return "".join(out)


def choose(messages, title: str) -> str | None:
    """Run the interactive loop on the controlling terminal."""
    if not messages:
        return None
    tty_in = open("/dev/tty", "r", encoding="utf-8", errors="replace")
    tty_out = open("/dev/tty", "w", encoding="utf-8", errors="replace")
    saved = termios.tcgetattr(tty_in)
    selected = len(messages) - 1  # Newest message, matching Pi's own default.
    offset = 0
    try:
        tty.setraw(tty_in.fileno())
        tty_out.write(HIDE_CURSOR)
        while True:
            rows = max(3, shutil.get_terminal_size((100, 24)).lines - 6)
            offset = min(max(offset, selected - rows + 1), selected)
            offset = max(0, min(offset, max(0, len(messages) - rows)))
            tty_out.write(render(messages, selected, offset, rows, title))
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
    result_path.write_text(json.dumps({"id": chosen}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
