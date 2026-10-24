#!/usr/bin/env python3
"""Single resolver for Mash's pinned artifacts.

Build scripts, preflight and the first-run installer all read pins through this
module so a version and its checksum cannot disagree between them.

Standard library only: the build runs it with whichever python3 the host or the
bundle provides, before any dependency has been installed.

    assets.py validate                 # schema + integrity of the manifest
    assets.py pins                     # the projection packaging/pins.txt holds
    assets.py check <pins-path>        # compare the file against the manifest
    assets.py resolve <component> <target>
    assets.py target                   # this host's target name
    assets.py components <target>      # components that must resolve
"""

from __future__ import annotations

import json
import os
import platform
import re
import sys
from pathlib import Path

DEFAULT_MANIFEST = Path(__file__).resolve().with_name("assets.json")

_HEX64 = re.compile(r"^[0-9a-f]{64}$")

# Archives the build knows how to extract, mapped to the member shape each one
# needs. `raw` is a bare binary downloaded as-is.
ARCHIVE_REQUIREMENTS = {
    "tar.gz": True,
    "tar.xz": True,
    "zip": True,
    "gz": True,
    "raw": True,
}

# Two strategies carry downloaded bytes and therefore need a url + checksum.
DOWNLOADED = {"binary", "source"}

_OS_ALIASES = {"darwin": "macos", "macos": "macos", "linux": "linux"}
_ARCH_ALIASES = {
    "arm64": "arm64",
    "aarch64": "arm64",
    "x86_64": "amd64",
    "amd64": "amd64",
    "x64": "amd64",
}


class AssetError(Exception):
    """A pin could not be resolved. Always names the component and target."""


def normalise_target(name: str) -> str:
    """`Darwin-arm64`, `darwin_arm64` and `macos-arm64` all mean macos-arm64."""
    text = str(name).strip().lower()
    os_part = next((alias for alias in ("darwin", "macos", "linux") if text.startswith(alias)), None)
    if os_part is None:
        raise AssetError(f"unsupported target {name!r}")
    arch_part = text[len(os_part):].lstrip("-_. ")
    os_name = _OS_ALIASES[os_part]
    arch = _ARCH_ALIASES.get(arch_part)
    if arch is None:
        raise AssetError(f"unsupported target {name!r}")
    return f"{os_name}-{arch}"


def host_target() -> str:
    return normalise_target(f"{platform.system().lower()}-{platform.machine().lower()}")


class Manifest:
    def __init__(self, data: dict, path: Path | None = None):
        self.path = path
        self.data = data
        self.targets = data.get("targets", {})
        self.supported = list(data.get("supportedTargets", []))
        self.components = data.get("components", {})
        self.pin_order = list(data.get("pinOrder", []))

    @classmethod
    def load(cls, path: os.PathLike | str | None = None) -> Manifest:
        chosen = Path(path) if path else DEFAULT_MANIFEST
        try:
            with open(chosen, encoding="utf-8") as handle:
                data = json.load(handle)
        except OSError as error:
            raise AssetError(f"cannot read {chosen}: {error}") from error
        except ValueError as error:
            raise AssetError(f"{chosen} is not valid JSON: {error}") from error
        return cls(data, chosen)

    # -- resolution -------------------------------------------------------

    def _component(self, name: str) -> dict:
        try:
            return self.components[name]
        except KeyError:
            raise AssetError(f"unknown component {name!r}") from None

    def version(self, name: str) -> str:
        version = self._component(name).get("version")
        if not version:
            raise AssetError(f"component {name!r} has no version")
        return str(version)

    def strategy(self, name: str) -> str:
        return str(self._component(name).get("strategy", ""))

    def applies_to(self, name: str, target: str) -> bool:
        """False when a component is deliberately macOS-only."""
        limited = self._component(name).get("targets")
        return limited is None or target in limited

    def resolve(self, name: str, target: str) -> dict:
        """Return the one artifact for this component and target.

        Raises instead of falling back to a host binary: a pin that cannot be
        resolved is a build failure, not an invitation to use whatever is on
        PATH.
        """
        component = self._component(name)
        target = normalise_target(target)
        if target not in self.supported:
            raise AssetError(f"component {name!r} has no entry for unsupported target {target!r}")

        strategy = component.get("strategy")
        artifacts = component.get("artifacts") or {}
        spec = artifacts.get(target) or artifacts.get("*")
        if spec is None:
            if strategy in DOWNLOADED:
                raise AssetError(f"component {name!r} has no artifact for {target}")
            # A package/npm/pip/git pin resolves from the platform, not a URL.
            return {"component": name, "target": target, "strategy": strategy,
                    "version": self.version(name),
                    "package": component.get("package"), "ref": component.get("ref"),
                    "repo": component.get("repo")}

        resolved = {"component": name, "target": target, "strategy": strategy,
                    "version": self.version(name)}
        resolved.update(spec)
        problem = spec_problem(name, target, resolved)
        if problem:
            raise AssetError(problem)
        return resolved

    def download(self, name: str, target: str) -> dict:
        """Like resolve(), but for components whose bytes are downloaded."""
        if self.strategy(name) not in DOWNLOADED:
            raise AssetError(f"component {name!r} is not a downloaded artifact")
        return self.resolve(name, target)

    # -- projections ------------------------------------------------------

    def pin_text(self) -> str:
        lines = []
        for name in self.pin_order:
            lines.append(f"{name} {self.version(name)}")
        return "\n".join(lines) + "\n"

    def pin_problems(self, path: os.PathLike | str) -> list[str]:
        chosen = Path(path)
        try:
            actual = chosen.read_text(encoding="utf-8")
        except OSError as error:
            return [f"cannot read {chosen}: {error}"]
        expected = self.pin_text()
        if actual == expected:
            return []
        want = expected.splitlines()
        have = actual.splitlines()
        problems = []
        for index in range(max(len(want), len(have))):
            want_line = want[index] if index < len(want) else "<missing>"
            have_line = have[index] if index < len(have) else "<missing>"
            if want_line != have_line:
                problems.append(f"line {index + 1}: manifest says {want_line!r}, file says {have_line!r}")
        return problems

    # -- integrity --------------------------------------------------------

    def problems(self) -> list[str]:
        problems: list[str] = []
        seen = set()

        for target in self.supported:
            if target not in self.targets:
                problems.append(f"supportedTargets names {target} but targets has no entry")

        if len(set(self.pin_order)) != len(self.pin_order):
            duplicates = sorted({n for n in self.pin_order if self.pin_order.count(n) > 1})
            problems.append(f"pinOrder lists duplicates: {', '.join(duplicates)}")

        for name in self.pin_order:
            if name not in self.components:
                problems.append(f"pinOrder names unknown component {name!r}")

        for name, component in self.components.items():
            if name in seen:
                problems.append(f"duplicate component {name!r}")
            seen.add(name)
            if not component.get("version"):
                problems.append(f"{name}: no version")
            strategy = component.get("strategy")
            if not strategy:
                problems.append(f"{name}: no strategy")
                continue
            if strategy not in DOWNLOADED:
                continue
            artifacts = component.get("artifacts") or {}
            if not artifacts:
                problems.append(f"{name}: {strategy} strategy with no artifacts")
                continue
            limited = component.get("targets") or self.supported
            for target in limited:
                spec = artifacts.get(target) or artifacts.get("*")
                if spec is None:
                    problems.append(f"{name}: no artifact for {target}")
                    continue
                merged = {"strategy": strategy, **spec}
                problem = spec_problem(name, target, merged)
                if problem:
                    problems.append(problem)
        return problems


def spec_problem(name: str, target: str, spec: dict) -> str | None:
    """Validate one artifact entry. Returns a message naming component+target."""
    url = spec.get("url")
    if not url:
        return f"{name} [{target}]: artifact has no url"
    if not str(url).startswith(("https://", "http://")):
        return f"{name} [{target}]: url is not absolute: {url}"
    digest = str(spec.get("sha256", ""))
    if not _HEX64.match(digest):
        return f"{name} [{target}]: sha256 must be 64 lowercase hex characters, got {digest!r}"
    archive = spec.get("archive")
    if archive not in ARCHIVE_REQUIREMENTS:
        known = ", ".join(sorted(ARCHIVE_REQUIREMENTS))
        return f"{name} [{target}]: archive must be one of {known}, got {archive!r}"
    if not spec.get("member"):
        return f"{name} [{target}]: archive {archive} needs a member path"
    return None


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command = argv[1]
    manifest = Manifest.load()

    if command == "validate":
        problems = manifest.problems()
        if problems:
            for problem in problems:
                print(f"assets: {problem}", file=sys.stderr)
            return 1
        print(f"assets: {len(manifest.components)} components, {len(manifest.supported)} targets")
        return 0

    if command == "pins":
        sys.stdout.write(manifest.pin_text())
        return 0

    if command == "check":
        if len(argv) < 3:
            print("usage: assets.py check <pins-path>", file=sys.stderr)
            return 2
        problems = manifest.pin_problems(argv[2])
        if problems:
            for problem in problems:
                print(f"assets: {argv[2]} {problem}", file=sys.stderr)
            return 1
        return 0

    if command == "target":
        print(host_target())
        return 0

    if command == "components":
        target = normalise_target(argv[2]) if len(argv) > 2 else host_target()
        for name in manifest.pin_order:
            if manifest.applies_to(name, target):
                print(name)
        return 0

    if command == "resolve-shell":
        # Shell callers cannot parse JSON without a dependency, so the same
        # resolution is offered as KEY=VALUE lines they can `eval`.
        if len(argv) < 4:
            print("usage: assets.py resolve-shell <component> <target>", file=sys.stderr)
            return 2
        try:
            spec = manifest.resolve(argv[2], argv[3])
        except AssetError as error:
            print(f"assets: {error}", file=sys.stderr)
            return 1
        for key in ("component", "target", "strategy", "version", "url", "sha256",
                    "archive", "member", "package", "ref", "repo"):
            value = spec.get(key)
            if value is None:
                continue
            print(f"{key.upper()}={value}")
        return 0

    if command == "resolve":
        if len(argv) < 4:
            print("usage: assets.py resolve <component> <target>", file=sys.stderr)
            return 2
        try:
            spec = manifest.resolve(argv[2], argv[3])
        except AssetError as error:
            print(f"assets: {error}", file=sys.stderr)
            return 1
        json.dump(spec, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print(f"assets: unknown command {command!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(_main(sys.argv))
    except AssetError as error:
        print(f"assets: {error}", file=sys.stderr)
        sys.exit(1)
