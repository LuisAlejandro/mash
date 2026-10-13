import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "helpers/mash-penpot-account-setup"


class PenpotAccountSetupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.data = self.home / ".mash"
        self.stack = self.data / "local/share/mash/design"
        self.bin = Path(self.tmp.name) / "app/bin"
        (self.stack / "bin").mkdir(parents=True)
        self.bin.mkdir(parents=True)
        (self.data / "setup").mkdir()
        (self.stack / "penpot.env").write_text(
            "PENPOT_LOCAL_EMAIL=dev@example.com\nPENPOT_LOCAL_PASSWORD=fake-test-password\nPENPOT_ACCESS_TOKEN=\n"
        )
        self.helper = self.bin / "mash-penpot-account-setup"
        self.helper.write_bytes(HELPER.read_bytes())
        self.helper.chmod(0o755)
        self.docker = self.bin / "docker"
        self.mds = self.stack / "bin/mds"
        self.mds.write_text(
            '#!/bin/bash\n'
            'test -z "${PENPOT_LOCAL_PASSWORD:-}" || exit 8\n'
            'printf "%s\\n" "$*" >> "$MASH_DATA_DIR/setup/mds-invocations"\n'
            'printf "PENPOT_ACCESS_TOKEN=fake-test-token\\n" >> "$MASH_DESIGN_STACK/penpot.env"\n'
        )
        self.mds.chmod(0o755)

    def run_helper(self):
        return subprocess.run(
            [str(self.helper), str(self.data)],
            env={**os.environ, "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )

    def test_refuses_symlinked_credentials(self):
        external = Path(self.tmp.name) / "external.env"
        external.write_text((self.stack / "penpot.env").read_text())
        (self.stack / "penpot.env").unlink()
        (self.stack / "penpot.env").symlink_to(external)
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.data / "setup/mds-invocations").exists())
        self.assertNotIn("PENPOT_ACCESS_TOKEN=fake-test-token", external.read_text())

    def test_deferred_then_created_once_when_docker_works(self):
        self.docker.write_text("#!/bin/sh\nexit 1\n")
        self.docker.chmod(0o755)
        first = self.run_helper()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertNotIn("fake-test-password", first.stdout + first.stderr)
        self.assertFalse((self.data / "setup/mds-invocations").exists())
        self.assertIn("pending", (self.data / "setup/penpot-account-setup.log").read_text())

        self.docker.write_text("#!/bin/sh\nexit 0\n")
        second = self.run_helper()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn("fake-test-password", second.stdout + second.stderr)
        self.assertEqual((self.data / "setup/mds-invocations").read_text().strip(), "setup --skip-auth")
        self.assertIn("PENPOT_ACCESS_TOKEN=fake-test-token", (self.stack / "penpot.env").read_text())
        self.assertEqual((self.data / "setup/penpot-mds.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual((self.data / "setup/mds-invocations").read_text().count("setup"), 1)


if __name__ == "__main__":
    unittest.main()
