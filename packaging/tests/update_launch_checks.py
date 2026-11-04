import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

from macos_update_fixture import ROOT, UpdateFixture


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
        waiter = subprocess.Popen(["/bin/bash", str(self.f.bin / "mash-update-gate"), "wait", str(self.f.app), str(self.f.data), attempt], env=self.f.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.4)
            self.assertIsNone(waiter.poll())
            self.assertFalse(result_file.exists())
            # A fresh executable generation becomes available after commit.
            target.unlink()
            target.write_text(f'#!/bin/bash\nprintf target >"{result_file}"\n')
            target.chmod(0o700)
            self.f.change(phase="awaiting-ready")
            self.assertEqual(waiter.wait(timeout=5), 0)
            self.assertEqual(result_file.read_text(), "target")
        finally:
            if waiter.poll() is None:
                waiter.terminate()
                waiter.wait(timeout=3)

    def test_native_patch_applies_twice_and_typechecks(self):
        src = pathlib.Path(os.environ.get("MASH_GHOSTTY_SRC", ROOT.parent / "ghostty"))
        if not (src / ".git").exists():
            self.skipTest("needs pinned Ghostty source for native patch proof")
        pin = __import__("json").loads((ROOT / "packaging/assets.json").read_text())["components"]["ghostty"]["commit"]
        files = ["macos/Sources/App/main.swift", "macos/Sources/App/AppDelegate.swift", "macos/Sources/App/MashMenus.swift", "src/apprt/gtk/ui/1.5/window.blp"]
        checkout = self.f.root / "source"
        for name in files:
            path = checkout / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(subprocess.check_output(["git", "-C", str(src), "show", f"{pin}:{name}"]))
        command = ["/bin/bash", str(ROOT / "packaging/helpers/mash-ghostty-patch-menu"), str(checkout)]
        for _ in range(2):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        native = (checkout / files[0]).read_text()
        self.assertLess(native.index("mashUpdateEntry()\nmashHandOffToSetup()"), native.index('if env["MASH_BIN"] != nil'))
        snippet = native.split("import MachO\n", 1)[1].split("// Mash: this binary", 1)[0]
        harness = self.f.root / "native.swift"
        harness.write_text('import AppKit\nimport Cocoa\nimport MachO\nclass TerminalController { static var all: [NSWindowController] { [] } }\nfunc mashSetupFailed(_ reason: String) -> Never { fatalError(reason) }\n' + snippet)
        checked = subprocess.run(["xcrun", "swiftc", "-typecheck", str(harness)], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        # A changed source must fail, not be mistaken for an applied patch.
        main = checkout / files[0]
        main.write_text(native.replace("mashUpdateEntry()\nmashHandOffToSetup()", "changedEntry()\nmashHandOffToSetup()"))
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
