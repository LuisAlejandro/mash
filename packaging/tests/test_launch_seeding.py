"""Exercise launch preservation and failure paths in disposable resource/home trees."""

import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LaunchSeedingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="mash-launch-seeding-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "home"
        self.data = self.home / ".mash"
        self.res = self.root / "resources-a"
        shutil.copytree(ROOT / "packaging/defaults", self.res / "defaults", symlinks=True)
        (self.res / "defaults/optional-programming.txt").write_text("")
        (self.res / "VERSION").write_text("9.9.8\n")
        (self.res / "bin").mkdir()
        for name in ("lib.sh", "launch-common.sh", "mash-shell"):
            shutil.copy(ROOT / "packaging" / name, self.res / "bin" / name)
        shutil.copy(ROOT / "packaging/helpers/mash-seed-sync", self.res / "bin")
        (self.res / "python/bin").mkdir(parents=True)
        (self.res / "python/bin/python3").symlink_to(sys.executable)
        self.env = {"HOME": str(self.home), "PATH": os.environ["PATH"],
                    "PYTHONDONTWRITEBYTECODE": "1", "MASH_SEED_PLATFORM": "Darwin",
                    "MASH_UNAME": "Darwin"}

    def shell(self, command, res=None):
        return subprocess.run(
            ["/bin/bash", "-c", command, "fixture", str(res or self.res),
             str(self.data), str(self.home)], env=self.env,
            capture_output=True, text=True, timeout=30,
        )

    def launch(self, res=None, setup=""):
        return self.shell('source "$1/bin/launch-common.sh"\n' + setup +
                          '\nif mash_seed_all "$1" "$2" "$3"; then exit 0; else exit 13; fi', res)

    def assert_launch(self, res=None):
        result = self.launch(res)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def config(self, relative):
        return self.data / "config" / relative

    def force_fresh(self):
        return self.shell('source "$1/bin/lib.sh"; if mash_force_updates "$3"; then exit 0; else exit 9; fi')

    def test_json_updates_preserve_grouped_minified_and_nested_properties(self):
        path = self.config("fresh/config.json")
        path.parent.mkdir(parents=True)
        examples = (
            '{\n  "check_for_updates": false, "theme": "user-theme",\n  "self_update": true\n}\n',
            '{"theme":"user-theme","editor":{"check_for_updates":true},"self_update":true}',
            '{"theme":"user-theme","check_for_updates":true,"self_update":true,"extra":[1,2]}',
        )
        for original in examples:
            with self.subTest(original=original):
                path.write_text(original)
                path.chmod(0o640)
                expected = {**json.loads(original), "check_for_updates": False, "self_update": False}
                result = self.force_fresh()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(path.read_text()), expected)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                before = (path.read_bytes(), path.stat().st_ino)
                self.assertEqual(self.force_fresh().returncode, 0)
                self.assertEqual((path.read_bytes(), path.stat().st_ino), before)

    def test_fresh_config_with_comments_or_trailing_commas_is_still_readable(self):
        path = self.config("fresh/config.json")
        path.parent.mkdir(parents=True)
        # Fresh parses its config as JSONC; a comment a person added is legal
        # input, and must not make every later launch fail closed.
        original = (
            '{\n  // keep my theme\n  "theme": "user-theme",\n'
            '  "check_for_updates": true,\n  /* Mash pins this below */\n'
            '  "self_update": true,\n  "url": "https://example.invalid/a//b",\n}\n'
        )
        path.write_text(original)
        result = self.force_fresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(path.read_text()),
            {
                "theme": "user-theme",
                "check_for_updates": False,
                "self_update": False,
                # A // inside a string is not a comment.
                "url": "https://example.invalid/a//b",
            },
        )

    def test_invalid_json_is_refused_without_replacement(self):
        path = self.config("fresh/config.json")
        path.parent.mkdir(parents=True)
        for original in ('{"check_for_updates":true,broken}', '[1,2]',
                         '{"check_for_updates":false,"self_update":false,"extra":NaN}'):
            with self.subTest(original=original):
                path.write_text(original)
                result = self.force_fresh()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_text(), original)

    def test_symlinked_fresh_config_is_not_replaced_or_followed(self):
        path = self.config("fresh/config.json")
        path.parent.mkdir(parents=True)
        outside = self.root / "outside.json"
        original = '{"theme":"user-theme","check_for_updates":true}'
        outside.write_text(original)
        path.symlink_to(outside)
        self.assertNotEqual(self.force_fresh().returncode, 0)
        self.assertTrue(path.is_symlink())
        self.assertEqual(outside.read_text(), original)

    def add_path_defaults(self):
        (self.data / "setup").mkdir(parents=True)
        (self.data / "setup/skills-choice").write_text("programming=true\n")
        notifier = self.res / "bin/mash-notify"
        notifier.write_text("#!/bin/sh\nexit 0\n")
        notifier.chmod(0o755)
        config = self.res / "defaults/plugins/dot.terminal-notifier/config.env"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("SETTING=initial\n")
        venv = self.res / "defaults/mash-config/venvs/mash-parallel"
        (venv / "bin").mkdir(parents=True)
        (venv / "pyvenv.cfg").write_text("home = /build/python/bin\nexecutable = /build/python/bin/python3\n")
        (venv / "bin/python").symlink_to("/build/python/bin/python3")
        (venv / "bin/python3").symlink_to("python")
        (venv / "bin/runner").write_text("#!/build/python\nprint('fixture')\n")

    def moved_resources(self):
        moved = self.root / "resources-b"
        shutil.copytree(self.res, moved, symlinks=True)
        return moved

    def test_same_version_relocation_retains_provenance_for_future_updates(self):
        self.add_path_defaults()
        self.assert_launch()
        moved = self.moved_resources()
        self.assert_launch(moved)
        self.assertIn(str(moved / "bin/herdr-pane"), self.config("ghostty/config").read_text())
        notifier = self.config("herdr/plugins/config/dot.terminal-notifier/config.env")
        venv = self.config("mash/venvs/mash-parallel")
        self.assertIn(str(moved / "bin/mash-notify"), notifier.read_text())
        self.assertEqual(os.readlink(venv / "bin/python"), str(moved / "python/bin/python3"))
        self.assertIn(str(moved / "python/bin"), (venv / "pyvenv.cfg").read_text())
        (moved / "VERSION").write_text("9.9.9\n")
        (moved / "defaults/plugins/dot.terminal-notifier/config.env").write_text("SETTING=updated\n")
        (moved / "defaults/mash-config/venvs/mash-parallel/pyvenv.cfg").write_text("home = /build/python/bin\ninclude-system-site-packages = false\n")
        self.assert_launch(moved)
        self.assertIn("SETTING=updated", notifier.read_text())
        self.assertIn("include-system-site-packages = false", (venv / "pyvenv.cfg").read_text())
        record = self.data / "local/state/seeded.json"
        before = record.read_bytes()
        self.assert_launch(moved)
        self.assertEqual(record.read_bytes(), before)

    def test_relocation_preserves_edited_config_and_venv_files(self):
        self.add_path_defaults()
        self.assert_launch()
        venv = self.config("mash/venvs/mash-parallel")
        metadata = venv / "pyvenv.cfg"
        custom = "home = /fixture/custom-python\nexecutable = /fixture/custom-python/python3\n"
        metadata.write_text(custom)
        interpreter = venv / "bin/python"
        interpreter.unlink()
        interpreter.symlink_to("/fixture/custom-python/python3")
        notifier = self.config("herdr/plugins/config/dot.terminal-notifier/config.env")
        notifier.write_text("NOTIFIER=/fixture/user-notifier\nUSER_SETTING=keep\n")
        ghostty = self.config("ghostty/config")
        ghostty.write_text(ghostty.read_text() + "# user terminal choice\n")
        before = {p: p.read_bytes() for p in (metadata, notifier, ghostty)}
        self.assert_launch(self.moved_resources())
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, path)
        self.assertEqual(os.readlink(interpreter), "/fixture/custom-python/python3")

    def test_old_provenance_without_resource_root_gets_one_safe_reconcile(self):
        self.assert_launch()
        record = self.data / "local/state/seeded.json"
        value = json.loads(record.read_text())
        value.pop("resource_root", None)
        record.write_text(json.dumps(value))
        moved = self.moved_resources()
        self.assert_launch(moved)
        self.assertIn(str(moved / "bin/herdr-pane"), self.config("ghostty/config").read_text())
        self.assertEqual(json.loads(record.read_text())["resource_root"], str(moved.resolve()))

    def test_missing_pet_snippet_never_overwrites_edited_configuration(self):
        config = self.config("pet/config.toml")
        config.parent.mkdir(parents=True)
        content = '[General]\nsnippetfile = "/fixture/my-snippets.toml"\neditor = "custom"\n'
        config.write_text(content)
        self.assert_launch()
        self.assertEqual(config.read_text(), content)
        self.assertTrue(self.config("pet/snippet.toml").is_file())

    def test_fallback_seeds_missing_pet_config_independently(self):
        (self.res / "bin/mash-seed-sync").unlink()
        snippet = self.config("pet/snippet.toml")
        snippet.parent.mkdir(parents=True)
        snippet.write_text("# user snippets\n")
        self.assert_launch()
        self.assertTrue(self.config("pet/config.toml").is_file())
        self.assertEqual(snippet.read_text(), "# user snippets\n")

    def test_stable_canonical_root_alias_does_not_reconcile_again(self):
        self.assert_launch()
        record = self.data / "local/state/seeded.json"
        before = record.read_bytes()
        alias = self.root / "resource-alias"
        alias.symlink_to(self.res, target_is_directory=True)
        self.assert_launch(alias)
        self.assertEqual(record.read_bytes(), before)

    def test_isolated_python_helpers_disable_bundle_bytecode_explicitly(self):
        # -I ignores PYTHONDONTWRITEBYTECODE, so -B must be an actual argument.
        python = self.res / "python/bin/python3"
        python.unlink()
        python.write_text('#!/bin/sh\ncase " $* " in *" -B "*) exec ' +
                          shlex.quote(sys.executable) + ' "$@" ;; *) exit 86 ;; esac\n')
        python.chmod(0o755)
        path = self.config("fresh/config.json")
        path.parent.mkdir(parents=True)
        path.write_text('{"check_for_updates":true}')
        self.assertEqual(self.force_fresh().returncode, 0)
        shutil.copy(ROOT / "packaging/helpers/mash-github-mcp", self.res / "bin")
        hosts = self.config("gh/hosts.yml")
        hosts.parent.mkdir()
        hosts.write_text("github.com:\n    oauth_token: gho_fixture_only\n")
        result = self.shell('/bin/bash "$1/bin/mash-github-mcp" --header "$2"')
        self.assertEqual(result.stdout.strip(), "Bearer gho_fixture_only")

    def test_fallback_does_not_recopy_an_existing_partial_user_venv(self):
        self.add_path_defaults()
        (self.res / "bin/mash-seed-sync").unlink()
        venv = self.config("mash/venvs/mash-parallel")
        (venv / "bin").mkdir(parents=True)
        runner = venv / "bin/runner"
        runner.write_text("# user runner\n")
        self.assert_launch()
        self.assertEqual(runner.read_text(), "# user runner\n")
        self.assertFalse((venv / "mash-parallel").exists())

    def test_missing_fresh_core_config_is_not_a_successful_seed(self):
        shutil.rmtree(self.res / "defaults/fresh")
        self.assertNotEqual(self.launch().returncode, 0)

    def test_github_header_migration_finishes_before_agents_can_start(self):
        self.assert_launch()
        shutil.copy(ROOT / "packaging/herdr-pane", self.res / "bin")
        library = self.res / "bin/lib.sh"
        library.write_text(library.read_text() + '\nmash_real_home() { printf "%s\\n" "$HOME"; }\n')
        hosts = self.config("gh/hosts.yml")
        hosts.write_text("github.com:\n    oauth_token: gho_fixture_only\n")
        mcp = self.data / "pi/agent/mcp.json"
        mcp.write_text(json.dumps({"mcpServers": {"github": {"x-mash": "mash-github",
                               "headers": {"Authorization": "!gh auth token --hostname github.com"}}}}))
        done = self.root / "manager-done"
        manager = self.res / "bin/mash-github-mcp"
        manager.write_text('#!/bin/sh\nsleep 0.2\n/bin/bash ' +
                           shlex.quote(str(ROOT / "packaging/helpers/mash-github-mcp")) +
                           ' "$@"\nprintf done >' + shlex.quote(str(done)) + '\n')
        manager.chmod(0o755)
        snapshot = self.root / "at-agent-start.json"
        herdr = self.res / "bin/herdr"
        herdr.write_text('#!/bin/sh\ncp ' + shlex.quote(str(mcp)) + ' ' +
                         shlex.quote(str(snapshot)) + '\n')
        herdr.chmod(0o755)
        result = subprocess.run(["/bin/bash", str(self.res / "bin/herdr-pane")],
                                env=self.env, capture_output=True, text=True, timeout=10)
        # The pre-fix asynchronous fixture is finite; let it exit before removing
        # its scratch tree even when the ordering assertion fails.
        until = time.monotonic() + 5
        while not done.exists() and time.monotonic() < until:
            time.sleep(0.02)
        self.assertTrue(done.exists(), "fixture manager did not finish")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        authorization = json.loads(snapshot.read_text())["mcpServers"]["github"]["headers"]["Authorization"]
        self.assertIn("--header", authorization)
        self.assertNotIn("auth token", authorization)

    def test_failed_assignment_filter_cannot_replace_a_config_with_empty_output(self):
        path = self.config("herdr/config.toml")
        path.parent.mkdir(parents=True)
        original = '# user settings\nupdate_channel = "user"\n'
        path.write_text(original)
        result = self.shell('source "$1/bin/lib.sh"; awk() { return 17; }; '
                            'if mash_force_updates "$3"; then exit 0; else exit 9; fi')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), original)
        self.assertEqual(list(self.data.glob("force.*")), [])

    def test_core_directory_failure_reaches_guarded_caller(self):
        blocked = self.config("herdr")
        blocked.parent.mkdir(parents=True)
        blocked.write_text("not a directory")
        self.assertNotEqual(self.launch().returncode, 0)

    def test_missing_core_template_reaches_guarded_caller(self):
        for name in ("config.toml", "config.linux.toml"):
            (self.res / "defaults/herdr" / name).unlink()
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse(self.config("herdr/config.toml").exists())

    def test_reconcile_failure_reaches_guarded_caller(self):
        helper = self.res / "bin/mash-seed-sync"
        helper.write_text("#!/bin/sh\nexit 7\n")
        self.assertNotEqual(self.launch().returncode, 0)

    def test_a_failed_provenance_write_does_not_block_the_launch(self):
        # The files are already reconciled; losing the record only means the
        # next launch reconciles again. Blocking every launch on it is worse.
        self.assert_launch()
        record = self.data / "local/state/seeded.json"
        record.unlink()
        record.mkdir()
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not record provenance", result.stderr)
        record.rmdir()
        self.assert_launch()

    def test_missing_core_library_copy_reaches_guarded_caller(self):
        (self.res / "bin/lib.sh").unlink()
        self.assertNotEqual(self.launch().returncode, 0)

    def test_optional_failure_is_named_but_core_still_starts(self):
        result = self.launch(setup="mash_seed_programming_skills() { return 7; }")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("optional", result.stderr.lower())
        self.assertTrue(self.config("ghostty/config").is_file())


if __name__ == "__main__":
    unittest.main()
