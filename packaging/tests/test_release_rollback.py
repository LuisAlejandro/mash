"""Rollback must stop Actions runs before allowing any ref deletion."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

FAKE_GH = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["HOME"])
args = sys.argv[1:]
with (root / "calls").open("a") as log:
    log.write(json.dumps(args) + "\n")
mode = os.environ["SCENARIO"]
if args == ["auth", "status"]:
    sys.exit(1 if mode == "auth-error" else 0)
if args[:2] == ["run", "cancel"]:
    if mode != "timeout":
        (root / ("done-" + args[2])).touch()
    sys.exit(1 if mode == "cancel-race" else 0)
if mode in ("list-error", "page-error"):
    if mode == "page-error":
        print("11")  # A later page fails after some IDs were already returned.
    sys.exit(1)
if args[0] == "api":
    workflow = next(arg for arg in args if arg.startswith("repos/")).split("/")[-2]
    branch = next(arg.removeprefix("branch=") for arg in args if arg.startswith("branch="))
elif args[:2] == ["run", "list"]:
    workflow = args[args.index("--workflow") + 1]
    branch = args[args.index("--branch") + 1]
else:
    sys.exit(2)
run_id = str({"push.yml": 1, "release.yml": 2, "artifacts.yml": 3}[workflow] * 10
             + {"release/0.3.0": 1, "0.3.0": 2}[branch])
seen = root / ("seen-" + run_id)
count = int(seen.read_text()) + 1 if seen.exists() else 1
seen.write_text(str(count))
active = mode != "empty" and not (root / ("done-" + run_id)).exists()
if mode == "late-dispatch":
    active = active and (run_id == "11" or (run_id == "32" and count > 1))
if "--json" in args and args[args.index("--json") + 1] == "status":
    print(1 if active else 0)
elif active:
    print(run_id)
'''


class ReleaseRollbackTest(unittest.TestCase):
    def test_release_stages_only_its_version_and_changelog_files(self):
        lines = (ROOT / "scripts/release.sh").read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip().startswith("git add "))
        end = next(i for i in range(start, len(lines)) if lines[i].strip().startswith("git commit "))
        with tempfile.TemporaryDirectory(prefix="mash-release-staging-") as tmp:
            home = Path(tmp)
            subprocess.run(["git", "init", "-q", tmp], check=True)
            (home / ".bumpversion.cfg").write_text(
                "[bumpversion]\ncurrent_version = 1.1.0\n"
                "[bumpversion:file:VERSION]\n[bumpversion:file:README.md]\n"
            )
            for name in ("VERSION", "README.md", "HISTORY.md", "unrelated.txt"):
                (home / name).write_text("fixture\n")
            subprocess.run(["/bin/bash", "-eu", "-c", "\n".join(lines[start:end])], cwd=home, check=True)
            staged = subprocess.check_output(
                ["git", "diff", "--cached", "--name-only"], cwd=home, text=True,
            ).splitlines()
            self.assertEqual(set(staged), {".bumpversion.cfg", "VERSION", "README.md", "HISTORY.md"})

    def test_dirty_rollback_stops_without_stashing_or_remote_actions(self):
        with tempfile.TemporaryDirectory(prefix="mash-dirty-rollback-") as tmp:
            home = Path(tmp)
            binary = home / "bin"
            binary.mkdir()
            for name in ("dirname", "grep"):
                (binary / name).symlink_to(shutil.which(name))
            git = binary / "git"
            git.write_text('''#!/bin/sh
printf '%s\\n' "$*" >>"$HOME/git-calls"
case "$1" in
  rev-parse) printf '.git\\n' ;;
  status) printf ' M unrelated.txt\\n' ;;
  *) exit 99 ;;
esac
''')
            gh = binary / "gh"
            gh.write_text('#!/bin/sh\nprintf called >"$HOME/gh-called"\nexit 98\n')
            for command in (git, gh):
                command.chmod(0o755)
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "scripts/rollback.sh"), "release"],
                cwd=home,
                env={"HOME": tmp, "PATH": str(binary), "VERSION": "0.3.0",
                     "NON_INTERACTIVE": "true"},
                capture_output=True, text=True, timeout=10,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            log = home / "git-calls"
            self.assertTrue(log.exists(), result.stdout + result.stderr)
            calls = log.read_text().splitlines()
            self.assertTrue(all(call.split()[0] in ("rev-parse", "status") for call in calls), calls)
            self.assertIn("Working directory is not clean", result.stdout)
            self.assertFalse((home / "gh-called").exists())

    def cancel(self, scenario):
        with tempfile.TemporaryDirectory(prefix="mash-rollback-") as tmp:
            home = Path(tmp)
            binary = home / "bin"
            binary.mkdir()
            gh = binary / "gh"
            gh.write_text(f"#!{sys.executable}\n" + FAKE_GH)
            gh.chmod(0o755)
            if scenario == "missing-gh":
                gh.unlink()
            result = subprocess.run(
                ["/bin/bash", "-eu", "-c", '''
source "$1"
print_step() { :; }
print_warning() { printf '%s\n' "$*" >&2; }
print_error() { printf '%s\n' "$*" >&2; }
# Collapse the legacy fixed-count polling loop in the timeout regression.
sleep() { :; }
seq() { printf '1\n'; }
release_cancel_matching_runs release/0.3.0 0.3.0
printf 'SAFE_TO_ROLLBACK\n'
''', "rollback-test", str(ROOT / "scripts/lib.sh")],
                cwd=home,
                env={**os.environ, "HOME": tmp, "PATH": str(binary),
                     "SCENARIO": scenario, "RELEASE_CI_POLL_SECONDS": "0",
                     "RELEASE_CI_TIMEOUT_SECONDS": "0" if scenario == "timeout" else "10"},
                capture_output=True, text=True, timeout=15,
            )
            log = home / "calls"
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_cancels_all_workflows_on_both_refs_and_waits_for_completion(self):
        result, calls = self.cancel("active")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("SAFE_TO_ROLLBACK", result.stdout)
        cancelled = [call[2] for call in calls if call[:2] == ["run", "cancel"]]
        self.assertEqual(set(cancelled), {"11", "12", "21", "22", "31", "32"})
        self.assertEqual(len(cancelled), 6)
        queries = [call for call in calls if call[0] == "api"]
        self.assertTrue(queries, "Actions queries must paginate, not hide older active runs")
        self.assertTrue(all("--paginate" in call for call in queries))

    def test_empty_run_list_needs_no_cancellation(self):
        result, calls = self.cancel("empty")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(call[:2] == ["run", "cancel"] for call in calls))

    def test_auth_list_errors_and_timeouts_block_ref_deletion(self):
        for scenario in ("missing-gh", "auth-error", "list-error", "page-error", "timeout"):
            with self.subTest(scenario=scenario):
                result, _ = self.cancel(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("SAFE_TO_ROLLBACK", result.stdout)

    def test_cancel_racing_with_completion_is_safe(self):
        result, _ = self.cancel("cancel-race")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rescans_and_cancels_a_late_dispatched_artifact_run(self):
        result, calls = self.cancel("late-dispatch")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(["run", "cancel", "32"], calls)


if __name__ == "__main__":
    unittest.main()
