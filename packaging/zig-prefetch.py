#!/usr/bin/env python3
"""Seed Zig's package cache before a Ghostty build, without Zig's git client.

Ghostty's dependency tree reaches four `git+https` packages (zigimg, uucode,
libvaxis, zig-gobject). Zig fetches those with its own HTTP/git implementation,
which performs a smart-HTTP capability handshake that fails intermittently on CI
runners:

    error: unable to discover remote git server capabilities: HttpConnectionClosing

That is a known Zig issue, not a bad pin, and retrying the same code path cannot
fix it. Every one of those dependencies pins a content hash, and Zig skips the
network entirely for a hash already in its cache. GitHub serves each pinned
commit as a plain tarball over one ordinary HTTPS GET, with no handshake, and
that tarball hashes identically to the git checkout.

So this walks the pinned dependency graph and fetches each package by tarball
into the cache the build will use. The pin still decides what is accepted: a
fetch whose resulting hash differs from the declared one fails the build rather
than seeding something else. A package already cached is not downloaded again,
which keeps warm builds free.

    zig-prefetch.py --zig <path> --src <ghostty checkout> [--global-cache-dir D]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tarfile
from pathlib import Path

# `.url`, `.hash` and `.path` are separate fields, and real manifests put
# comments and `.lazy` between them, so fields are read in document order and
# each url is paired with the hash that follows it rather than matched as a
# single block.
FIELD = re.compile(r"\.(url|hash|path)\s*=\s*\"([^\"]*)\"")

# git+https://github.com/<owner>/<repo>[.git][?query]#<40-hex commit>
GITHUB_GIT = re.compile(
    r"^git\+https://github\.com/([^/?#]+)/([^/?#]+?)(?:\.git)?(?:\?[^#]*)?#([0-9a-fA-F]{40})$"
)


def dependencies(zon_text: str) -> list[tuple[str, str, str | None]]:
    """Dependencies in declaration order as (kind, value, hash).

    kind is "url" for a fetched package, carrying its pinned hash, or "path" for
    a vendored one inside the same checkout, which has no hash.
    """
    found: list[tuple[str, str, str | None]] = []
    pending_url: str | None = None
    for kind, value in FIELD.findall(zon_text):
        if kind == "url":
            pending_url = value
        elif kind == "path":
            found.append(("path", value, None))
        elif pending_url is not None:
            found.append(("url", pending_url, value))
            pending_url = None
    return found


def tarball_url(url: str) -> str | None:
    """The codeload tarball for a GitHub git+https pin, or None to leave it be."""
    match = GITHUB_GIT.match(url)
    if match is None:
        return None
    owner, repo, commit = match.groups()
    return f"https://github.com/{owner}/{repo}/archive/{commit}.tar.gz"


def nested_manifest(archive: Path) -> str | None:
    """A package's own build.zig.zon, read out of its cached tarball.

    `zig fetch` caches a package as `p/<hash>.tar.gz` and extracts it only at
    build time, so a dependency's own pins are read from the archive rather than
    from a directory that does not exist yet.
    """
    try:
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                parts = member.name.split("/")
                if member.isfile() and len(parts) == 2 and parts[1] == "build.zig.zon":
                    handle = tar.extractfile(member)
                    return None if handle is None else handle.read().decode("utf-8", errors="replace")
    except (tarfile.TarError, OSError):
        return None
    return None


def global_cache_dir(zig: str) -> Path:
    """Where this zig keeps packages, when the caller did not name a directory."""
    out = subprocess.run([zig, "env"], capture_output=True, text=True, check=True).stdout
    match = re.search(r"\.global_cache_dir\s*=\s*\"([^\"]+)\"", out)
    if match is None:
        raise SystemExit("zig-prefetch: could not read global_cache_dir from `zig env`")
    return Path(match.group(1))


def fetch(zig: str, src: Path, cache: Path | None, url: str) -> str:
    """Fetch one package and return the hash Zig computed for it."""
    command = [zig, "fetch"]
    if cache is not None:
        command += ["--global-cache-dir", str(cache)]
    command.append(url)
    # Run from the checkout: `zig fetch` expects to sit under a build.zig.
    result = subprocess.run(command, cwd=src, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"zig-prefetch: fetching {url} failed\n{result.stdout}{result.stderr}".rstrip()
        )
    return result.stdout.strip().splitlines()[-1].strip()


def prefetch(zig: str, src: Path, packages: Path, explicit_cache: Path | None) -> tuple[int, int]:
    """Seed every pinned package the checkout depends on. Returns (seen, downloaded)."""
    root = src / "build.zig.zon"
    if not root.is_file():
        raise SystemExit(f"zig-prefetch: {root} does not exist")

    # A work item is one manifest plus the directory its relative paths resolve
    # against. Manifests read out of a tarball have no directory, so their path
    # dependencies stay inside that archive and are left to the build.
    queue: list[tuple[str, Path | None]] = [(root.read_text(errors="replace"), src)]
    visited_paths = {root.resolve()}
    seen: set[str] = set()
    downloaded = 0

    while queue:
        manifest, base = queue.pop()
        for kind, value, want in dependencies(manifest):
            if kind == "path":
                if base is None:
                    continue
                nested_path = (base / value / "build.zig.zon").resolve()
                if nested_path.is_file() and nested_path not in visited_paths:
                    visited_paths.add(nested_path)
                    queue.append((nested_path.read_text(errors="replace"), nested_path.parent))
                continue

            assert want is not None
            if want in seen:
                continue
            seen.add(want)
            cached = packages / f"{want}.tar.gz"
            if not cached.is_file():
                # A git pin goes through the tarball; anything else is already a
                # plain download and is fetched exactly as the manifest declares.
                source = tarball_url(value) or value
                got = fetch(zig, src, explicit_cache, source)
                if got != want:
                    raise SystemExit(
                        "zig-prefetch: refusing to seed a package that does not match its pin\n"
                        f"  dependency: {value}\n  fetched as: {source}\n"
                        f"  expected:   {want}\n  got:        {got}"
                    )
                downloaded += 1
            nested = nested_manifest(cached) if cached.is_file() else None
            if nested:
                queue.append((nested, None))

    return len(seen), downloaded


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("--global-cache-dir", default=None)
    args = parser.parse_args(argv)

    explicit_cache = Path(args.global_cache_dir) if args.global_cache_dir else None
    cache = explicit_cache if explicit_cache else global_cache_dir(args.zig)
    seen, downloaded = prefetch(args.zig, Path(args.src), cache / "p", explicit_cache)
    print(f"zig-prefetch: {seen} pinned packages, {downloaded} downloaded")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
