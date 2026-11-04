"""Verifier acceptance, rejection, ordering, cancellation and handoff."""
import pathlib
import plistlib
import shutil
import unittest

from macos_update_fixture import UpdateFixture


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

    def cleanup_source(self):
        source = (self.f.bin / "mash-update-verify").read_text()
        return "cleanup() {" + source.split("cleanup() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"

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
{self.cleanup_source()}
work="{self.f.work}" sibling="{sibling}" mnt="" handed_off=0
status=0
mash_update_run 1 fixture-copy "{child}" "$work" "$sibling" "{observed}" || status=$?
[ "$status" = 124 ] || exit 2
busy="$MU_COMMAND_BUSY"
(exit 1); cleanup
cleanup_status=$?
alive=0; kill -0 "$busy" 2>/dev/null && alive=1
kept=0; [ -d "$work" ] && [ -d "$sibling" ] && kept=1
wait "$busy" || true
printf 'status=%s alive=%s kept=%s cleanup=%s\\n' "$status" "$alive" "$kept" "$cleanup_status"
[ "$kept" = 1 ] && [ "$(cat "{observed}")" = kept ]
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("status=124 alive=1 kept=1 cleanup=1", result.stdout)
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
{self.cleanup_source()}
work="{self.f.work}" sibling="{sibling}" mnt="{mount}" handed_off=0
(exit 1); cleanup
cleanup_status=$?
kept=0; [ -d "$work" ] && [ -d "$sibling" ] && kept=1
[ -z "${{MU_COMMAND_BUSY:-}}" ] || wait "$MU_COMMAND_BUSY" || true
printf 'kept=%s cleanup=%s\\n' "$kept" "$cleanup_status"
[ "$kept" = 1 ]
''')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("kept=1 cleanup=1", result.stdout)
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


if __name__ == "__main__":
    unittest.main()
