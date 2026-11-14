#!/usr/bin/env python3
"""Hourly badge polling, with kernel-owned per-mode exclusive ownership."""
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import threading
import time


def main():
    state = os.environ.get("XDG_STATE_HOME", "")
    if not state.startswith("/") or "/.mash/" not in state:
        return 1
    state = Path(state)
    startup = sys.argv[1:] == ["--startup"]
    root = Path(os.environ.get("HERDR_PLUGIN_STATE_DIR", str(state / "herdr/plugins/pr-watch-focus")))
    root.mkdir(parents=True, exist_ok=True)
    # Never unlink: contenders must always lock the same inode. Legacy PID
    # directories use different names and cannot suppress or steal this lock.
    with (root / ("startup.flock" if startup else "poll.flock")).open("a") as held:
        try:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        return poll(state, startup)


def poll(state, startup):
    value = os.environ.get("MASH_WATCH_INTERVAL_SECONDS", "3600")
    interval = max(60, int(value)) if value.isascii() and value.isdecimal() else 3600
    watchers = [
        ("pr-watch-repo", os.environ.get("PR_WATCH_REPO_BIN") or shutil.which("pr-watch-repo")),
        ("git-status-watch", os.environ.get("GIT_STATUS_WATCH_BIN") or shutil.which("git-status-watch")),
    ]
    stopped = threading.Event()
    active = None

    def stop(signum, frame):
        stopped.set()
        if active is not None:
            try:
                os.killpg(active.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    attempts = 0
    while not stopped.is_set():
        failed = False
        for name, binary in watchers:
            if stopped.is_set():
                break
            directory = state / name
            directory.mkdir(parents=True, exist_ok=True)
            if not binary or not os.access(binary, os.X_OK):
                continue
            with (directory / "poll.log").open("a") as log:
                try:
                    # close_fds prevents watchers (and their children) holding
                    # the lock after the poller dies. Each watcher has its own
                    # process group so shutdown never signals unrelated work.
                    active = subprocess.Popen([binary], stdout=log, stderr=log,
                                              close_fds=True, start_new_session=True)
                    while True:
                        try:
                            status = active.wait(timeout=0.2)
                            break
                        except subprocess.TimeoutExpired:
                            if stopped.is_set():
                                try:
                                    status = active.wait(timeout=3)
                                except subprocess.TimeoutExpired:
                                    os.killpg(active.pid, signal.SIGKILL)
                                    status = active.wait()
                                break
                except OSError as error:
                    log.write(f"poll failed ({error})\n")
                    status = 1
                finally:
                    active = None
                failed |= status != 0
                stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                log.write(f"{stamp} poll {'ok' if status == 0 else f'failed ({status})'}\n")
        if stopped.is_set():
            break
        if failed and attempts < 12:
            delay = 5
            attempts += 1
        else:
            attempts = 12
            if startup:
                return 0
            delay = interval
        stopped.wait(delay)
    return 0


if __name__ == "__main__":
    sys.exit(main())
