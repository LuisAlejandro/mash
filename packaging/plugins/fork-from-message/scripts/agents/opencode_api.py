#!/usr/bin/env python3
"""Minimal OpenCode HTTP client for listing and forking user messages.

OpenCode keeps sessions in a background server, so forking is an API call rather
than a subprocess. Three behaviours drive this design:

* The `opencode api` CLI truncates large responses, so message listing talks to
  the server over HTTP directly.
* The server authenticates with HTTP Basic using the password in service.json.
* `order` is not honoured on the message endpoint and every page is capped, so
  pages are followed through the opaque cursor and sorted locally.
"""

from __future__ import annotations

import base64
import json
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Mapping


REQUEST_TIMEOUT_SECONDS = 20
PAGE_LIMIT = 50
MAX_PAGES = 100
SERVICE_FILE = Path.home() / ".config" / "opencode" / "service.json"


class OpenCodeError(RuntimeError):
    """An OpenCode transport or API failure."""


class OpenCodeApi:
    """Talks to the running OpenCode server for one session."""

    def __init__(
        self,
        base_url: str | None = None,
        password: str | None = None,
        executable: str = "opencode",
    ) -> None:
        self.executable = executable
        self.base_url = (base_url or self._discover_url()).rstrip("/")
        self.password = password if password is not None else self._discover_password()

    def _discover_url(self) -> str:
        try:
            completed = subprocess.run(
                [self.executable, "api", "GET", "/api/info"],
                capture_output=True,
                text=True,
                timeout=REQUEST_TIMEOUT_SECONDS,
                check=True,
            )
        except FileNotFoundError as exc:
            raise OpenCodeError(f"OpenCode executable not found: {self.executable}") from exc
        except (subprocess.SubprocessError, OSError) as exc:
            raise OpenCodeError("Could not reach the OpenCode server.") from exc
        try:
            urls = json.loads(completed.stdout).get("urls")
        except ValueError as exc:
            raise OpenCodeError("OpenCode returned unreadable server info.") from exc
        if not isinstance(urls, list) or not urls or not isinstance(urls[0], str):
            raise OpenCodeError("OpenCode reported no server URL. Is the service running?")
        return urls[0]

    def _discover_password(self) -> str:
        try:
            password = json.loads(SERVICE_FILE.read_text()).get("password")
        except (OSError, ValueError) as exc:
            raise OpenCodeError(f"Could not read the OpenCode service password: {exc}") from exc
        if not isinstance(password, str) or not password:
            raise OpenCodeError("The OpenCode service password is missing or empty.")
        return password

    def _request(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        token = base64.b64encode(f"opencode:{self.password}".encode()).decode()
        headers = {"Authorization": f"Basic {token}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base_url}{path}", data=data, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                payload = response.read().decode()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:200]
            raise OpenCodeError(f"OpenCode returned HTTP {exc.code} for {path}: {detail}") from exc
        except (urllib.error.URLError, OSError) as exc:
            raise OpenCodeError(f"Could not reach the OpenCode server for {path}: {exc}") from exc
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError as exc:
            raise OpenCodeError(f"OpenCode returned invalid JSON for {path}.") from exc

    def session(self, session_id: str) -> Mapping[str, Any]:
        data = self._request("GET", f"/api/session/{session_id}")
        if not isinstance(data, dict) or not isinstance(data.get("data"), dict):
            raise OpenCodeError(f"OpenCode returned no session record for {session_id}.")
        return data["data"]

    def _all_messages(self, session_id: str) -> list[Mapping[str, Any]]:
        """Every message in the session, following the opaque page cursor."""
        seen: dict[str, Mapping[str, Any]] = {}
        cursor: str | None = None
        for _ in range(MAX_PAGES):
            query = f"?limit={PAGE_LIMIT}" + (f"&cursor={cursor}" if cursor else "")
            payload = self._request("GET", f"/api/session/{session_id}/message{query}")
            if not isinstance(payload, dict):
                raise OpenCodeError("OpenCode returned an unexpected message page.")
            page = payload.get("data")
            if not isinstance(page, list):
                raise OpenCodeError("OpenCode returned no message list.")
            for message in page:
                if isinstance(message, dict) and isinstance(message.get("id"), str):
                    seen[message["id"]] = message
            nxt = (payload.get("cursor") or {}).get("next")
            if not page or not isinstance(nxt, str) or not nxt:
                break
            cursor = nxt
        return list(seen.values())

    def fork_messages(self, session_id: str) -> list[dict[str, str]]:
        """User messages worth forking, oldest first.

        OpenCode forks *before* the chosen message, so the first user message has
        no earlier history and would branch into an empty session. It is dropped
        rather than offered as a choice that produces nothing useful.
        """
        users = [m for m in self._all_messages(session_id) if m.get("type") == "user"]
        users.sort(key=lambda m: (m.get("time", {}).get("created", 0), m.get("id", "")))
        result = [
            {"id": m["id"], "text": m.get("text") if isinstance(m.get("text"), str) else ""}
            for m in users
        ]
        if not result:
            raise OpenCodeError("This session has no user message to fork from.")
        forkable = result[1:]
        if not forkable:
            raise OpenCodeError(
                "This session has only its first user message, which has no earlier "
                "history to fork from."
            )
        return forkable

    def fork(self, session_id: str, before_message_id: str) -> str:
        """Fork before `before_message_id` and return the new session id."""
        payload = self._request(
            "POST", f"/api/session/{session_id}/fork", {"before": before_message_id}
        )
        if not isinstance(payload, dict) or not isinstance(payload.get("data"), dict):
            raise OpenCodeError("OpenCode returned no forked session.")
        new_id = payload["data"].get("id")
        if not isinstance(new_id, str) or not new_id:
            raise OpenCodeError("OpenCode forked the session but reported no new session id.")
        if new_id == session_id:
            raise OpenCodeError("OpenCode reported the source session id after forking.")
        # A fork is only useful once the server can serve it back; this also
        # catches a fork that was created and immediately discarded.
        self.session(new_id)
        return new_id

    def delete(self, session_id: str) -> None:
        try:
            self._request("DELETE", f"/api/session/{session_id}")
        except OpenCodeError:
            pass
