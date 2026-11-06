import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

from macos_update_fixture import ROOT, UpdateFixture, pinned_fork_text


class LaunchGateTests(unittest.TestCase):
    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)

    def test_waiter_does_not_initialize_old_runtime_and_reexecs_target(self):
        # Keep the owner alive in this test process, not a shell that already
        # exited. The gate must wait while this exact boot/process is active.
        attempt = self.f.begin()
        self.f.change(phase="quiescing", owner_pid=os.getpid(),
                      owner_start=self.f.inspector("stamp", os.getpid()))
        target = self.f.app / "Contents/MacOS/mash-terminal"
        result_file = self.f.root / "launched"
        waiter = subprocess.Popen(["/bin/bash", str(self.f.bin / "mash-update-gate"), "wait", str(self.f.app), str(self.f.data), attempt], env={**self.f.env, "FIXTURE_LAUNCH_MARKER": str(result_file)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.4)
            self.assertIsNone(waiter.poll())
            self.assertFalse(result_file.exists())
            # A fresh executable generation becomes available after commit.
            target.unlink()
            shutil.copy(self.f.candidate / "Contents/MacOS/mash-terminal", target)
            for name in ("Contents/Info.plist", "Contents/Resources/VERSION"):
                shutil.copy(self.f.candidate / name, self.f.app / name)
            self.f.change(phase="awaiting-ready", expected_uuid=self.f.inspector("uuid", target))
            self.assertEqual(waiter.wait(timeout=5), 0)
            self.assertEqual(result_file.read_text(), "target")
        finally:
            if waiter.poll() is None:
                waiter.terminate()
                waiter.wait(timeout=3)

    def test_orphan_publication_locks_can_be_reclaimed(self):
        lock = self.f.data / "local/state/update-install.lock"
        transaction = self.f.data / "local/state/update-transaction.plist"
        for kind in ("empty", "id-only", "different-id-terminal", "different-id-preparing"):
            with self.subTest(kind=kind):
                shutil.rmtree(lock, ignore_errors=True)
                transaction.unlink(missing_ok=True)
                if kind.startswith("different-id"):
                    self.f.begin()
                    self.f.change(phase="confirmed" if kind.endswith("terminal") else "preparing", owner_start="dead-fixture-owner")
                else:
                    lock.mkdir()
                if kind != "empty":
                    (lock / "id").write_text("00000000-0000-4000-8000-000000000004\n")
                attempt = self.f.begin()
                self.assertEqual((lock / "id").read_text().strip(), attempt)
                self.assertEqual(self.f.state()["phase"], "preparing")

    def test_live_and_unresolved_transactions_remain_protected(self):
        attempt = self.f.begin()
        lock = self.f.data / "local/state/update-install.lock"
        transaction = self.f.data / "local/state/update-transaction.plist"
        for phase in ("preparing", "swap-intent", "awaiting-ready", "recovery-required", "unknown"):
            with self.subTest(phase=phase):
                self.f.change(phase=phase, owner_pid=os.getpid(), owner_start=self.f.inspector("stamp", os.getpid()))
                before = transaction.read_bytes()
                result = self.f.shell(f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; mash_update_begin "{self.f.app}" 9.9.9 9.9.8 "{self.f.work}"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(transaction.read_bytes(), before)
                self.assertEqual((lock / "id").read_text().strip(), attempt)
        self.f.change(phase="confirmed")
        shutil.rmtree(lock)
        lock.write_text("not an attempt directory")
        self.assertNotEqual(self.f.shell(f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; mash_update_begin "{self.f.app}" 9.9.9 9.9.8 "{self.f.work}"').returncode, 0)
        self.assertEqual(lock.read_text(), "not an attempt directory")

    def test_corrupt_or_live_published_state_is_not_replaced_without_a_lock(self):
        self.f.begin()
        lock = self.f.data / "local/state/update-install.lock"
        transaction = self.f.data / "local/state/update-transaction.plist"
        shutil.rmtree(lock)
        original = self.f.state()
        for fields in ({"phase": "unknown"}, {"schema": "invalid"}, {"id": "invalid"}, {"owner_pid": os.getpid(), "owner_start": self.f.inspector("stamp", os.getpid())}):
            with self.subTest(fields=fields):
                self.f.change(**original)
                self.f.change(**fields)
                before = transaction.read_bytes()
                result = self.f.shell(f'source "{self.f.bin}/mash-update-common"; mash_update_init "{self.f.data}"; mash_update_begin "{self.f.app}" 9.9.9 9.9.8 "{self.f.work}"')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(transaction.read_bytes(), before)
                shutil.rmtree(lock, ignore_errors=True)

    def test_dead_quiescing_is_retryable_even_if_image_uuid_matches(self):
        attempt = self.f.begin()
        marker = self.f.root / "launch-marker"
        image = self.f.app / "Contents/MacOS/mash-terminal"
        self.f.change(phase="quiescing", owner_start="dead-fixture-owner", expected_uuid=self.f.inspector("uuid", image))
        result = subprocess.run(["/bin/bash", str(self.f.bin / "mash-update-gate"), "wait", str(self.f.app), str(self.f.data), attempt], env={**self.f.env, "FIXTURE_LAUNCH_MARKER": str(marker)}, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")
        self.assertEqual(marker.read_text(), "target")
        self.f.begin()

    def test_awaiting_mismatch_waits_for_a_live_worker(self):
        attempt = self.f.begin()
        marker = self.f.root / "launch-marker"
        self.f.change(phase="awaiting-ready", owner_pid=os.getpid(), owner_start=self.f.inspector("stamp", os.getpid()), expected_uuid=self.f.inspector("uuid", self.f.candidate / "Contents/MacOS/mash-terminal"))
        waiter = subprocess.Popen(["/bin/bash", str(self.f.bin / "mash-update-gate"), "wait", str(self.f.app), str(self.f.data), attempt], env={**self.f.env, "FIXTURE_LAUNCH_MARKER": str(marker)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.35)
            self.assertIsNone(waiter.poll(), "mismatched image started while the worker was active")
            self.assertFalse(marker.exists())
            self.f.change(phase="recovery-required")
            self.assertEqual(waiter.wait(timeout=5), 0)
        finally:
            if waiter.poll() is None:
                waiter.terminate()
                waiter.wait(timeout=3)

    def test_notice_distinguishes_pre_swap_failure_from_exchange_intent(self):
        self.f.begin()
        self.f.change(phase="quiescing", owner_pid=os.getpid(), owner_start=self.f.inspector("stamp", os.getpid()))
        resources = self.f.app / "Contents/Resources"
        (resources / "bin").mkdir()
        for name in ("mash-update-common", "mash-update-processes", "mash-update-gate", "mash-update-swap"):
            shutil.copy(self.f.bin / name, resources / "bin" / name)
        (self.f.data / "local/state/update-checked").write_text(str(int(time.time())))
        command = ["/bin/bash", str(ROOT / "packaging/helpers/mash-update-notice"), str(resources), str(self.f.data)]
        self.assertEqual(subprocess.run(command, env=self.f.env, timeout=10).returncode, 0)
        self.assertEqual(self.f.state()["phase"], "quiescing")
        self.f.change(owner_start="dead-fixture-owner")
        self.assertEqual(subprocess.run(command, env=self.f.env, timeout=10).returncode, 0)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")
        self.f.begin()
        self.f.change(phase="swap-intent", owner_start="dead-fixture-owner",
                      old_uuid=self.f.inspector("uuid", self.f.app / "Contents/MacOS/mash-terminal"),
                      expected_uuid=self.f.inspector("uuid", self.f.candidate / "Contents/MacOS/mash-terminal"))
        self.assertEqual(subprocess.run(command, env=self.f.env, timeout=10).returncode, 0)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")

    def test_pinned_native_lifecycle_typechecks(self):
        main = pinned_fork_text("macos/Sources/App/main.swift")
        if main is None:
            # Without a fork checkout the proof is skipped; with one configured
            # a missing pin is a real failure, not a silent skip.
            if os.environ.get("MASH_GHOSTTY_SRC"):
                self.fail("MASH_GHOSTTY_SRC is set but the pinned fork commit cannot be read")
            self.skipTest("needs pinned Ghostty source for the native lifecycle proof")
        self.assertIn("mashUpdateEntry()\nmashHandOffToSetup()", main)
        snippet = main.split("import MachO\n", 1)[1].split("// Mash: this binary", 1)[0]
        harness = self.f.root / "native.swift"
        harness.write_text('import AppKit\nimport Cocoa\nimport MachO\nclass TerminalController { static var all: [NSWindowController] { [] } }\nfunc mashSetupFailed(_ reason: String) -> Never { fatalError(reason) }\n' + snippet)
        checked = subprocess.run(["xcrun", "swiftc", "-typecheck", str(harness)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)


class NativeEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory(prefix="mash-native-entry-", dir="/tmp")
        cls.addClassCleanup(temporary.cleanup)
        directory = pathlib.Path(temporary.name)
        main = pinned_fork_text("macos/Sources/App/main.swift")
        if main is None:
            if os.environ.get("MASH_GHOSTTY_SRC"):
                raise AssertionError("MASH_GHOSTTY_SRC is set but the pinned fork commit cannot be read")
            raise unittest.SkipTest("needs pinned Ghostty source for the native lifecycle")
        snippet = main[main.index("import MachO\n"):].split("\nmashUpdateEntry()\n", 1)[0]
        snippet = snippet.replace("FileManager.default.homeDirectoryForCurrentUser", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!)')
        snippet = snippet.replace("Bundle.main.bundleURL", 'URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_APP"]!)')
        snippet = snippet.replace("Bundle.main.resourceURL", 'Optional(URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_APP"]!).appendingPathComponent("Contents/Resources"))')
        snippet = snippet.replace('Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""', '"9.9.9"')
        header = '''import Foundation
import Darwin
final class NSAlert {
 var messageText = ""; var informativeText = ""
 func addButton(withTitle: String) {}
 func runModal() { print("RECOVERY") }
}
struct FixtureWindow { var isVisible: Bool { true } }
struct FixtureController { let window: FixtureWindow? }
enum TerminalController { static var all: [FixtureController] { [] } }
func mashSetupFailed(_ reason: String) -> Never { print("SETUP_FAILED: " + reason); exit(73) }
'''
        footer = '''
if CommandLine.arguments.contains("observe-only") {
 mashUpdateObserveReadiness()
 print(mashUpdateReadinessTimer == nil ? "NO_TIMER" : "TIMER")
 exit(0)
}
let countURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!).appendingPathComponent("entry-count")
let count = (Int((try? String(contentsOf: countURL, encoding: .utf8)) ?? "0") ?? 0) + 1
try String(count).write(to: countURL, atomically: true, encoding: .utf8)
if count >= 3 { print("LOOP"); exit(74) }
mashUpdateEntry()
print("ENTRY_RETURNED")
'''
        source = directory / "entry.swift"
        source.write_text(header + snippet + footer)
        cls.binary = directory / "entry"
        result = subprocess.run(["xcrun", "swiftc", str(source), "-o", str(cls.binary)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def setUp(self):
        self.f = UpdateFixture()
        self.addCleanup(self.f.close)
        self.target = self.f.app / "Contents/MacOS/mash-terminal"
        shutil.copy(self.binary, self.target)
        resources = self.f.app / "Contents/Resources/bin"
        resources.mkdir()
        for name in ("mash-update-common", "mash-update-gate", "mash-update-processes", "mash-update-swap"):
            shutil.copy(self.f.bin / name, resources / name)
        self.f.begin()

    def enter(self, *args):
        (self.f.data.parent / "entry-count").write_text("0")
        return subprocess.run([str(self.target), *args], env=self.f.env, capture_output=True, text=True, timeout=10)

    def test_completed_records_for_other_locations_do_not_block_entry(self):
        for phase in ("confirmed", "cancelled", "failed-before-swap"):
            with self.subTest(phase=phase):
                self.f.change(phase=phase, app=self.f.root / "PreviousLocation.app")
                result = self.enter()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("ENTRY_RETURNED", result.stdout)

    def test_foreign_unresolved_and_invalid_records_remain_blocked(self):
        original = self.f.state()
        for fields in ([{"phase": phase, "app": self.f.root / "Other.app"} for phase in ("preparing", "ready", "quiescing", "swap-intent", "awaiting-ready", "recovery-required")]
                       + [{"phase": "confirmed", "schema": "invalid"}, {"phase": "confirmed", "id": "invalid"}, {"phase": "confirmed", "app": "not-absolute.app"}]):
            with self.subTest(fields=fields):
                self.f.change(**original)
                self.f.change(**fields)
                self.assertEqual(self.enter().returncode, 73)

    def test_dead_awaiting_image_mismatch_reaches_recovery_without_a_loop(self):
        self.f.change(phase="awaiting-ready", owner_start="dead-fixture-owner", expected_uuid=self.f.inspector("uuid", self.f.candidate / "Contents/MacOS/mash-terminal"))
        for name in ("mash-update-common", "mash-update-gate", "mash-update-processes"):
            shutil.copy(self.f.bin / name, self.f.work / name)
        result = self.enter()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("LOOP", result.stdout)
        self.assertIn("bootstrap", self.f.calls.read_text())
        self.assertEqual(self.f.state()["phase"], "recovery-required")
        self.assertEqual((self.f.data.parent / "entry-count").read_text(), "1")

    def test_4_lost_work_uses_installed_recovery_without_blocking_launch(self):
        resources = self.f.app / "Contents/Resources/bin"
        resources.mkdir(parents=True, exist_ok=True)
        for name in ("mash-update-common", "mash-update-gate", "mash-update-processes"):
            shutil.copy(self.f.bin / name, resources / name)
        self.f.change(phase="quiescing", owner_start="dead-before-reboot")
        shutil.rmtree(self.f.work)
        result = self.enter()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("SETUP_FAILED", result.stdout)
        self.assertEqual(self.f.state()["phase"], "failed-before-swap")

    def test_2_matching_uuid_with_wrong_version_is_not_admitted(self):
        for name in ("mash-update-common", "mash-update-gate", "mash-update-processes"):
            shutil.copy(self.f.bin / name, self.f.work / name)
        self.f.change(phase="awaiting-ready", owner_start="dead-owner", candidate="9.9.10", expected_uuid=self.f.inspector("uuid", self.target))
        result = self.enter()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("ENTRY_RETURNED", result.stdout)
        self.assertEqual(self.f.state()["phase"], "recovery-required")

    def test_readiness_stays_location_bound_and_expected_image_can_enter(self):
        self.f.change(phase="awaiting-ready", expected_uuid=self.f.inspector("uuid", self.target))
        self.assertEqual(self.enter().returncode, 0)
        self.assertEqual(self.enter("observe-only").stdout.strip(), "TIMER")
        self.f.change(app=self.f.root / "Other.app")
        self.assertEqual(self.enter("observe-only").stdout.strip(), "NO_TIMER")


if __name__ == "__main__":
    unittest.main()
