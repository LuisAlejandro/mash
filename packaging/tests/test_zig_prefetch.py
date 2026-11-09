#!/usr/bin/env python3
"""The Ghostty dependency pre-seeding that keeps Zig's git client out of a build.

Four of Ghostty's pins are `git+https`, and Zig's own git client fails
intermittently on CI ("unable to discover remote git server capabilities"),
which cost a release four times. packaging/zig-prefetch.py seeds those pins from
tarballs instead. These tests run without network: `zig` is a stub that records
its arguments and answers with whatever hash the case wants.
"""

import importlib.util
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "packaging" / "zig-prefetch.py"

spec = importlib.util.spec_from_file_location("zig_prefetch", HELPER)
zig_prefetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zig_prefetch)


class ManifestParsingTest(unittest.TestCase):
    """A dependency's url, hash and path are separate fields in document order."""

    def test_comments_and_lazy_between_url_and_hash(self):
        # Ghostty's real manifest puts a comment above the url and `.lazy` after
        # the hash; pairing by adjacency alone would drop these.
        manifest = textwrap.dedent(
            """
            .{
                .dependencies = .{
                    .vaxis = .{
                        // rockorager/libvaxis
                        .url = "https://deps.files.ghostty.org/vaxis-abc.tar.gz",
                        .hash = "vaxis-0.6.0-AAAA",
                        .lazy = true,
                    },
                    .zigimg = .{
                        .url = "git+https://github.com/zigimg/zigimg#aabbccdd",
                        .hash = "zigimg-0.1.0-BBBB",
                    },
                },
            }
            """
        )
        self.assertEqual(
            zig_prefetch.dependencies(manifest),
            [
                ("url", "https://deps.files.ghostty.org/vaxis-abc.tar.gz", "vaxis-0.6.0-AAAA"),
                ("url", "git+https://github.com/zigimg/zigimg#aabbccdd", "zigimg-0.1.0-BBBB"),
            ],
        )

    def test_path_dependencies_are_reported_without_a_hash(self):
        manifest = '.{ .dependencies = .{ .translate_c = .{ .path = "./pkg/translate-c" } } }'
        self.assertEqual(
            zig_prefetch.dependencies(manifest), [("path", "./pkg/translate-c", None)]
        )

    def test_a_manifest_without_dependencies_yields_nothing(self):
        self.assertEqual(zig_prefetch.dependencies('.{ .name = .probe }'), [])


class TarballUrlTest(unittest.TestCase):
    """Only GitHub git pins are rewritten; everything else is fetched as declared."""

    def test_plain_commit_pin(self):
        self.assertEqual(
            zig_prefetch.tarball_url(
                "git+https://github.com/zigimg/zigimg#d695acd97c02e57bb151e8f659d1280f5cd6ca70"
            ),
            "https://github.com/zigimg/zigimg/archive/d695acd97c02e57bb151e8f659d1280f5cd6ca70.tar.gz",
        )

    def test_dot_git_suffix_is_dropped(self):
        self.assertEqual(
            zig_prefetch.tarball_url(
                "git+https://github.com/rockorager/libvaxis.git#c1e1f23be38951c425cdf31af455ba23ef178940"
            ),
            "https://github.com/rockorager/libvaxis/archive/c1e1f23be38951c425cdf31af455ba23ef178940.tar.gz",
        )

    def test_ref_query_is_ignored_in_favour_of_the_commit(self):
        # zig-gobject pins ?ref=<branch>#<commit>; the commit is what identifies
        # the tree, so the branch must not end up in the tarball URL.
        self.assertEqual(
            zig_prefetch.tarball_url(
                "git+https://github.com/ianprime0509/zig?ref=zig-gobject#08e338bce1897fa893c721dcafa97055321aec93"
            ),
            "https://github.com/ianprime0509/zig/archive/08e338bce1897fa893c721dcafa97055321aec93.tar.gz",
        )

    def test_non_github_and_plain_urls_are_left_alone(self):
        for url in (
            "git+https://codeberg.org/ifreund/zig-wayland#aabbccddeeff00112233445566778899aabbccdd",
            "https://deps.files.ghostty.org/libxev-9ce8e8e.tar.gz",
        ):
            with self.subTest(url=url):
                self.assertIsNone(zig_prefetch.tarball_url(url))


def write_package(packages: Path, package_hash: str, manifest: str = "") -> Path:
    """Write a cached package tarball the way `zig fetch` leaves one behind."""
    packages.mkdir(parents=True, exist_ok=True)
    archive = packages / f"{package_hash}.tar.gz"
    with tempfile.TemporaryDirectory() as staging:
        inner = Path(staging) / package_hash
        inner.mkdir()
        (inner / "build.zig").write_text("// package\n")
        if manifest:
            (inner / "build.zig.zon").write_text(manifest)
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(inner, arcname=package_hash)
    return archive


class NestedManifestTest(unittest.TestCase):
    """Transitive pins are read from the cached tarball, not an extracted dir."""

    def test_manifest_is_read_from_inside_the_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp) / "p"
            write_package(packages, "vaxis-0.6.0-AAAA", '.{ .name = .vaxis }')
            self.assertEqual(
                zig_prefetch.nested_manifest(packages / "vaxis-0.6.0-AAAA.tar.gz"),
                ".{ .name = .vaxis }",
            )

    def test_a_package_without_a_manifest_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp) / "p"
            write_package(packages, "leaf-0.0.0-CCCC")
            self.assertIsNone(zig_prefetch.nested_manifest(packages / "leaf-0.0.0-CCCC.tar.gz"))


class StubZig:
    """A `zig` that never touches the network and records every fetch."""

    def __init__(self, tmp: Path, answers: dict, cache: Path):
        self.calls = tmp / "fetches.txt"
        self.path = tmp / "zig"
        lines = "\n".join(f'  "{url}") echo "{h}" ;;' for url, h in answers.items())
        self.path.write_text(
            textwrap.dedent(
                f"""\
                #!/bin/bash
                if [ "$1" = env ]; then
                  printf '.{{\\n    .global_cache_dir = "{cache}",\\n}}\\n'
                  exit 0
                fi
                url="${{@: -1}}"
                echo "$url" >>"{self.calls}"
                case "$url" in
                {lines}
                  *) echo "stub zig: unexpected fetch $url" >&2; exit 1 ;;
                esac
                """
            )
        )
        self.path.chmod(0o755)

    def fetched(self) -> list[str]:
        if not self.calls.exists():
            return []
        return [line for line in self.calls.read_text().splitlines() if line]


class PrefetchWalkTest(unittest.TestCase):
    """The walk reaches transitive and vendored pins, and honours the hashes."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        self.src = self.tmp / "ghostty"
        self.src.mkdir()
        self.cache = self.tmp / "cache"
        self.packages = self.cache / "p"
        self.packages.mkdir(parents=True)

    def run_helper(self, answers):
        stub = StubZig(self.tmp, answers, self.cache)
        result = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--zig",
                str(stub.path),
                "--src",
                str(self.src),
                "--global-cache-dir",
                str(self.cache),
            ],
            capture_output=True,
            text=True,
        )
        return result, stub

    def test_git_pins_are_fetched_as_tarballs_including_transitive_ones(self):
        # vaxis is a plain tarball dependency, and only its own manifest reveals
        # the git pin that broke CI, so the walk has to open the cached archive.
        self.src.joinpath("build.zig.zon").write_text(
            """
            .{ .dependencies = .{
                .vaxis = .{
                    .url = "https://deps.files.ghostty.org/vaxis.tar.gz",
                    .hash = "vaxis-0.6.0-AAAA",
                },
            } }
            """
        )
        vaxis_manifest = """
            .{ .dependencies = .{
                .zigimg = .{
                    .url = "git+https://github.com/zigimg/zigimg#d695acd97c02e57bb151e8f659d1280f5cd6ca70",
                    .hash = "zigimg-0.1.0-BBBB",
                },
            } }
            """

        # vaxis is already cached, so the walk must still open its archive to
        # discover the git pin underneath it.
        write_package(self.packages, "vaxis-0.6.0-AAAA", vaxis_manifest)
        result, stub = self.run_helper(
            {
                "https://github.com/zigimg/zigimg/archive/d695acd97c02e57bb151e8f659d1280f5cd6ca70.tar.gz": "zigimg-0.1.0-BBBB"
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            stub.fetched(),
            [
                "https://github.com/zigimg/zigimg/archive/d695acd97c02e57bb151e8f659d1280f5cd6ca70.tar.gz"
            ],
            "the transitive git pin must be fetched as a tarball",
        )
        self.assertNotIn(
            "git+https", " ".join(stub.fetched()), "no git+https URL may reach zig"
        )

    def test_vendored_path_dependencies_are_followed(self):
        # pkg/glslang is a path dependency with pins of its own; missing it is
        # what made the first version of this helper leave the build offline-broken.
        self.src.joinpath("build.zig.zon").write_text(
            '.{ .dependencies = .{ .glslang = .{ .path = "./pkg/glslang" } } }'
        )
        vendored = self.src / "pkg" / "glslang"
        vendored.mkdir(parents=True)
        vendored.joinpath("build.zig.zon").write_text(
            """
            .{ .dependencies = .{
                .glslang_src = .{
                    .url = "https://deps.files.ghostty.org/glslang.tar.gz",
                    .hash = "glslang-0.0.0-DDDD",
                },
            } }
            """
        )
        result, stub = self.run_helper(
            {"https://deps.files.ghostty.org/glslang.tar.gz": "glslang-0.0.0-DDDD"}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stub.fetched(), ["https://deps.files.ghostty.org/glslang.tar.gz"])

    def test_already_cached_packages_are_not_downloaded_again(self):
        self.src.joinpath("build.zig.zon").write_text(
            """
            .{ .dependencies = .{
                .vaxis = .{
                    .url = "https://deps.files.ghostty.org/vaxis.tar.gz",
                    .hash = "vaxis-0.6.0-AAAA",
                },
            } }
            """
        )
        write_package(self.packages, "vaxis-0.6.0-AAAA")
        result, stub = self.run_helper({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stub.fetched(), [], "a warm cache must cost no downloads")
        self.assertIn("0 downloaded", result.stdout)

    def test_a_hash_that_does_not_match_the_pin_fails_the_build(self):
        # The pin stays the authority: a tarball that is not the pinned tree must
        # never be seeded as if it were.
        self.src.joinpath("build.zig.zon").write_text(
            """
            .{ .dependencies = .{
                .zigimg = .{
                    .url = "git+https://github.com/zigimg/zigimg#d695acd97c02e57bb151e8f659d1280f5cd6ca70",
                    .hash = "zigimg-0.1.0-EXPECTED",
                },
            } }
            """
        )
        result, _ = self.run_helper(
            {
                "https://github.com/zigimg/zigimg/archive/d695acd97c02e57bb151e8f659d1280f5cd6ca70.tar.gz": "zigimg-0.1.0-SOMETHINGELSE"
            }
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match its pin", result.stderr)
        self.assertIn("zigimg-0.1.0-EXPECTED", result.stderr)
        self.assertIn("zigimg-0.1.0-SOMETHINGELSE", result.stderr)

    def test_a_failed_fetch_stops_the_build(self):
        self.src.joinpath("build.zig.zon").write_text(
            """
            .{ .dependencies = .{
                .gone = .{
                    .url = "https://deps.files.ghostty.org/gone.tar.gz",
                    .hash = "gone-0.0.0-FFFF",
                },
            } }
            """
        )
        result, _ = self.run_helper({})  # the stub rejects any unexpected URL
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed", result.stderr)

    def test_a_missing_checkout_is_reported_rather_than_silently_skipped(self):
        result, _ = self.run_helper({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build.zig.zon", result.stderr)


class BuildWiringTest(unittest.TestCase):
    """Both build paths must seed the cache before Ghostty is compiled."""

    def test_macos_and_linux_builds_prefetch_before_zig_build(self):
        for script in ("packaging/carry.sh", "packaging/build-linux.sh"):
            with self.subTest(script=script):
                text = (ROOT / script).read_text()
                self.assertIn("zig-prefetch.py", text)
                self.assertLess(
                    text.index("zig-prefetch.py"),
                    text.index('"$zig" build'),
                    "the cache must be seeded before the build runs",
                )

    def test_the_release_signs_through_the_timestamp_retry(self):
        # Apple's timestamp service failed once mid-release and threw away a
        # 45-minute build; every timestamped signature goes through the retry.
        text = (ROOT / "packaging/release.sh").read_text()
        self.assertIn("mash_codesign()", text)
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("codesign ") and "--timestamp" in stripped:
                self.fail(f"timestamped signature bypasses the retry: {stripped}")
        self.assertIn('mash_codesign --force --timestamp --sign "$identity" "$dist/Mash.dmg"', text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
