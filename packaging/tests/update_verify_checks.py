"""Verifier acceptance, rejection, ordering, cancellation and handoff."""
import pathlib
import plistlib
import shutil
import subprocess
import time
import unittest

from macos_update_fixture import ROOT, UpdateFixture


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)
        (self.f.data / "local/state/update-notice").write_text("9.9.9\n")

    def test_prepared_candidate_is_final_and_job_is_attempt_scoped(self):
        result = self.f.verify()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = self.f.state()
        self.assertEqual(state["phase"], "handoff")
        self.assertEqual(state["worker_claimed"], "1")
        self.assertEqual(state["handoff_released"], "1")
        self.assertTrue(pathlib.Path(state["work"]).is_relative_to(self.f.data / "local/state/update-attempts"))
        self.assertTrue(pathlib.Path(state["sibling"], "Mash.app/Contents/MacOS/mash-terminal").exists())
        job = plistlib.loads(pathlib.Path(state["work"], "update-job.plist").read_bytes())
        self.assertEqual(job["Label"], "app.mash.update." + state["id"])
        self.assertIn("--attempt", job["ProgramArguments"])
        self.assertEqual(self.f.calls.read_text().count("ditto "), 1)
        self.assertNotIn("bootout", self.f.calls.read_text())
        self.assertNotIn("quit ", self.f.calls.read_text())
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
        self.assertIn("Prepared", self.f.data.joinpath("local/state/mash-update.log").read_text().title())

    def test_an_accepted_offer_is_not_asked_again(self):
        result = self.f.verify("n", MASH_UPDATE_CONFIRMED="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Type y", result.stdout)
        self.assertEqual(self.f.state()["phase"], "handoff")
        self.assertIn("bootstrap", self.f.calls.read_text())

    def test_cancellation_cleans_only_preparation(self):
        result = self.f.verify("n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.f.state()["phase"], "cancelled")
        self.assertNotIn("bootstrap", self.f.calls.read_text())
        self.assertFalse(list(self.f.app.parent.glob(".mash-update-*")))
        self.assertTrue((self.f.data / "local/state/update-notice").exists())

    def test_trust_and_preparation_failures_leave_old_app(self):
        for setting in ("FAKE_TEAM", "FAKE_CODESIGN_RC", "FAKE_SPCTL_RC", "FAKE_DOWNLOAD_RC", "FAKE_MOUNT_RC", "FAKE_COPY_RC", "FAKE_DETACH_RC", "FAKE_BOOTSTRAP_RC"):
            with self.subTest(setting=setting):
                result = self.f.verify(**{setting: "FOREIGN" if setting == "FAKE_TEAM" else "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.f.state()["phase"], "failed-before-swap")
                self.assertNotIn("quit ", self.f.calls.read_text())
                self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")
                if setting == "FAKE_DETACH_RC":
                    state = self.f.state()
                    self.assertTrue(pathlib.Path(state["sibling"]).is_dir())
                    self.assertIn("retained preparation", (self.f.data / "local/state/mash-update.log").read_text())
                    # These exact paths belong to this disposable fixture.
                    shutil.rmtree(state["sibling"])
                    shutil.rmtree(state["work"])
                else:
                    self.assertFalse(list(self.f.app.parent.glob(".mash-update-*")))

    def test_wrong_version_or_bundle_identity_is_rejected(self):
        for key, value in (("CFBundleIdentifier", "other.app"), ("CFBundleShortVersionString", "0.0.0"), ("CFBundleVersion", "0.0.0")):
            with self.subTest(key=key):
                path = self.f.candidate / "Contents/Info.plist"
                original = path.read_bytes()
                metadata = plistlib.loads(original)
                metadata[key] = value
                path.write_bytes(plistlib.dumps(metadata))
                result = self.f.verify()
                path.write_bytes(original)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.f.state()["phase"], "failed-before-swap")
                self.assertNotIn("bootstrap", self.f.calls.read_text())
        (self.f.candidate / "Contents/Resources/VERSION").write_text("0.0.0\n")
        self.assertNotEqual(self.f.verify().returncode, 0)

    def test_cleanup_keeps_a_timed_out_childs_inputs_until_it_exits(self):
        attempt = self.f.begin()
        sibling = self.f.app.parent / ".mash-update-ABCDEF"
        sibling.mkdir()
        observed = self.f.root / "child-observed"
        child = self.f.root / "finite-copy"
        child.write_text('''#!/bin/bash
trap '' TERM
sleep 4
if [ -d "$1" ] && [ -d "$2" ]; then printf kept >"$3"; else printf lost >"$3"; fi
''')
        child.chmod(0o700)
        result = self.f.shell(f'''set -u
source "{self.f.bin}/mash-update-common"
mash_update_init "{self.f.data}"
MU_ID="{attempt}"
mash_update_finish failed-before-swap
work="{self.f.work}" sibling="{sibling}" mnt=""
status=0
mash_update_run 1 fixture-copy "{child}" "$work" "$sibling" "{observed}" || status=$?
[ "$status" = 124 ] || exit 2
busy="$MU_COMMAND_BUSY"
(exit 1); mash_update_abandon_preparation "$work" "$sibling" "$mnt"; cleanup_status=$?
alive=0; kill -0 "$busy" 2>/dev/null && alive=1
kept=0; [ -d "$work" ] && [ -d "$sibling" ] && kept=1
wait "$busy" || true
printf 'status=%s alive=%s kept=%s cleanup=%s\\n' "$status" "$alive" "$kept" "$cleanup_status"
[ "$kept" = 1 ] && [ "$(cat "{observed}")" = kept ]
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("status=124 alive=1 kept=1 cleanup=0", result.stdout)
        self.assertIn("retained preparation", (self.f.data / "local/state/mash-update.log").read_text())
        self.assertEqual((self.f.app / "Contents/Resources/VERSION").read_text().strip(), "9.9.8")

    def test_clock_failure_keeps_the_started_command_identifiable(self):
        inspector = self.f.bin / "mash-update-processes"
        inspector.rename(inspector.with_suffix(".real"))
        inspector.write_text('''#!/bin/bash
if [ "$1" = now ]; then exit 1; fi
exec "${0}.real" "$@"
''')
        inspector.chmod(0o700)
        result = self.f.shell(f'''source "{self.f.bin}/mash-update-common"
mash_update_init "{self.f.data}"
status=0
mash_update_run 1 clock-failure /bin/sleep 1 || status=$?
owned="${{MU_COMMAND_BUSY:-}}"
wait || true
printf 'status=%s owned=%s\\n' "$status" "$owned"
[ "$status" = 1 ] && [ -n "$owned" ]
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cleanup_detach_is_bounded_and_retains_unfinished_preparation(self):
        attempt = self.f.begin()
        sibling = self.f.app.parent / ".mash-update-ABCDEF"
        for mode in ("failure", "timeout"):
            with self.subTest(mode=mode):
                self.f.work.mkdir(exist_ok=True)
                sibling.mkdir(exist_ok=True)
                mount = self.f.work / "mount"
                mount.mkdir(exist_ok=True)
                if mode == "timeout":
                    inspector = self.f.bin / "mash-update-processes"
                    inspector.rename(inspector.with_suffix(".real"))
                    inspector.write_text('''#!/bin/bash
if [ "$1" = now ]; then
 value=0; [ ! -f "$CALLS.clock" ] || read -r value <"$CALLS.clock"
 value=$((value + 61)); printf '%s\\n' "$value" >"$CALLS.clock"; echo "$value"
else
 exec "${0}.real" "$@"
fi
''')
                    inspector.chmod(0o700)
                    self.f.stub("hdiutil", "trap '' TERM; sleep 2; exit 1")
                else:
                    self.f.stub("hdiutil", "exit 1")
                result = self.f.shell(f'''set -u
source "{self.f.bin}/mash-update-common"
mash_update_init "{self.f.data}"
MU_ID="{attempt}"
mash_update_finish failed-before-swap
work="{self.f.work}" sibling="{sibling}" mnt="{mount}"
mash_update_abandon_preparation "$work" "$sibling" "$mnt"; cleanup_status=$?
kept=0; [ -d "$work" ] && [ -d "$sibling" ] && kept=1
[ -z "${{MU_COMMAND_BUSY:-}}" ] || wait "$MU_COMMAND_BUSY" || true
printf 'kept=%s cleanup=%s\\n' "$kept" "$cleanup_status"
[ "$kept" = 1 ]
''')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("kept=1 cleanup=0", result.stdout)
                log = (self.f.data / "local/state/mash-update.log").read_text()
                self.assertIn("start=cleanup-detach", log)
                self.assertIn("retained preparation", log)
                if mode == "timeout":
                    self.assertIn("end=cleanup-detach exit=124", log)

    def test_live_legacy_job_is_not_stopped(self):
        self.f.stub("launchctl", 'echo "launchctl $*" >>"$CALLS"; case "$1" in print) echo "    pid = 12345" ;; esac')
        result = self.f.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootout", self.f.calls.read_text())
        self.assertNotIn("curl ", self.f.calls.read_text())

    def test_progress_helper_reads_status_and_closes(self):
        binary = self.f.root / "mash-update-progress"
        subprocess.run(
            [
                "xcrun", "--sdk", "macosx", "clang", "-Wall", "-Wextra", "-Werror", "-O2",
                "-mmacosx-version-min=14.0", "-fobjc-arc", "-framework", "AppKit",
                str(ROOT / "packaging/helpers/mash-update-progress.m"), "-o", str(binary),
            ],
            check=True,
        )
        status = self.f.root / "status"
        status.write_text("mode bytes\nlabel Downloading Mash 9.9.9\ndone 4096\ntotal 4096\nfraction 700\n")
        parsed = subprocess.check_output([str(binary), "check", str(status)], text=True)
        self.assertEqual(parsed, "mode=bytes fraction=700 done=4096 total=4096 label=Downloading Mash 9.9.9\n")
        mutex = self.f.root / "progress.mutex"
        pinned = (self.f.root / "pinned-by-caller").open("w")
        pinned.write("pin")
        pinned.flush()
        proc = subprocess.Popen(
            [str(binary), "serve", str(status), str(mutex)],
            stdout=subprocess.PIPE,
            text=True,
            cwd=str(self.f.app),
            pass_fds=(pinned.fileno(),),
        )
        pid = int(proc.stdout.readline().strip())
        proc.stdout.close()
        pinned.close()
        self.addCleanup(lambda: subprocess.run(["kill", "-TERM", str(pid)], stderr=subprocess.DEVNULL, check=False))
        self.assertEqual(proc.wait(timeout=5), 0)
        self.assertEqual(subprocess.check_output(["ps", "-o", "ppid=", "-p", str(pid)], text=True).strip(), "1")
        deadline = time.time() + 2
        while True:
            owned = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-p", str(pid)], capture_output=True, text=True)
            cwd = subprocess.run(["/usr/sbin/lsof", "-n", "-P", "-a", "-p", str(pid), "-d", "cwd"], capture_output=True, text=True)
            cwd_name = cwd.stdout.split()[-1] if cwd.stdout.split() else ""
            if "pinned-by-caller" not in owned.stdout and cwd_name == "/":
                break
            if time.time() >= deadline:
                self.fail(owned.stdout + cwd.stdout)
            time.sleep(0.05)
        listed = subprocess.check_output(
            [str(self.f.bin / "mash-update-processes"), "list", str(self.f.app), str(self.f.data)],
            text=True,
        )
        self.assertFalse(any(line.split()[:1] == [str(pid)] for line in listed.splitlines()))
        busy = subprocess.run([str(binary), "serve", str(status), str(mutex)], capture_output=True, text=True)
        self.assertEqual(busy.returncode, 2)
        status.write_text("mode close\nlabel Closing\ndone 0\ntotal 0\nfraction 1000\n")
        deadline = time.time() + 3
        while time.time() < deadline and subprocess.run(["kill", "-0", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0:
            time.sleep(0.1)
        self.assertNotEqual(subprocess.run(["kill", "-0", str(pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode, 0)

    def test_progress_window_tracks_bytes_and_is_reused(self):
        stub = self.f.bin / "mash-update-progress"
        # The sleeper must not inherit the pipe this helper's pid is read from.
        stub.write_text('#!/bin/bash\necho "progress-bin $0" >>"$CALLS"\necho "progress $*" >>"$CALLS"\nsleep 120 >/dev/null 2>&1 &\necho $!\n')
        stub.chmod(0o700)

        def stop_stub():
            state_dir = self.f.data / "local/state"
            if not state_dir.is_dir():
                return
            for owner in state_dir.glob("update-progress-*.owner"):
                parts = owner.read_text().split()
                if parts:
                    subprocess.run(["kill", "-TERM", parts[0]], stderr=subprocess.DEVNULL, check=False)

        self.addCleanup(stop_stub)
        result = self.f.verify("y", FAKE_LENGTH="4096")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.f.calls.read_text()
        self.assertEqual(calls.count("progress serve "), 1)
        self.assertIn("update-attempts/mash-update-", calls)
        self.assertNotIn(str(self.f.app), calls[calls.find("progress-bin"):].split("\n", 1)[0])
        log = (self.f.data / "local/state/mash-update.log").read_text()
        self.assertIn("progress mode=bytes", log)
        self.assertIn("total=4096", log)
        self.assertIn("fraction=760", log)
        self.assertIn("fraction=900", log)
        state = self.f.state()
        pid, stamp = (self.f.data / "local/state" / f"update-progress-{state['id']}.owner").read_text().split()
        self.f.inspector("alive", pid, stamp)
        again = self.f.shell(
            f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; '
            f'MU_ID="{state["id"]}"; mash_update_progress'
        )
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(self.f.calls.read_text().count("progress serve "), 1)
        hidden = self.f.shell(
            f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; '
            f'MU_ID="{state["id"]}"; mash_update_hide_progress'
        )
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertNotEqual(subprocess.run([str(self.f.bin / "mash-update-processes"), "alive", pid, stamp]).returncode, 0)

    def test_progress_cannot_signal_the_app_or_run_from_inside_it(self):
        attempt = self.f.begin()
        terminal = self.f.start(self.f.app / "Contents/MacOS/mash-terminal")
        stamp = self.f.inspector("stamp", terminal.pid)
        owner = self.f.data / "local/state" / f"update-progress-{attempt}.owner"
        owner.write_text(f"{terminal.pid} {stamp}\n")
        hidden = self.f.shell(
            f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; '
            f'MU_ID="{attempt}"; mash_update_hide_progress'
        )
        self.assertEqual(hidden.returncode, 0, hidden.stdout + hidden.stderr)
        self.assertIsNone(terminal.poll())
        self.assertIn(
            f"progress hide left pid={terminal.pid} running",
            (self.f.data / "local/state/mash-update.log").read_text(),
        )
        bundled = self.f.app / "Contents/Resources/bin"
        bundled.mkdir()
        marker = self.f.root / "progress-ran"
        script = bundled / "mash-update-progress"
        script.write_text(f'#!/bin/bash\ntouch "{marker}"\necho $$\n')
        script.chmod(0o700)
        work = pathlib.Path(self.f.state()["work"])
        (work / "mash-update-progress").symlink_to(script)
        shown = self.f.shell(
            f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; '
            f'MU_ID="{attempt}"; mash_update_progress_show'
        )
        self.assertNotEqual(shown.returncode, 0, shown.stdout + shown.stderr)
        self.assertFalse(marker.exists())
        self.assertIsNone(terminal.poll())


if __name__ == "__main__":
    unittest.main()
