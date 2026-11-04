"""Disposable updater fixture. System trust/network/UI commands are stand-ins;
process identity, property lists, mutexes and atomic exchange remain real.
"""
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


class UpdateFixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mash-update-test-", dir="/tmp")
        self.root = pathlib.Path(self.temp.name).resolve()
        self.app = self.root / "Applications/Mash.app"
        self.candidate = self.root / "candidate/Mash.app"
        self.data = self.root / "home/.mash"
        self.bin = self.root / "bin"
        self.fake = self.root / "fake"
        self.calls = self.root / "calls"
        self.work = self.root / "mash-update-ABCDEF"
        for path in (self.bin, self.fake, self.work, self.data / "local/state", self.data / "run"):
            path.mkdir(parents=True)
        self.calls.touch()
        for name in ("mash-update-common", "mash-update-verify", "mash-update-apply", "mash-update-gate"):
            shutil.copy(ROOT / "packaging/helpers" / name, self.bin / name)
            (self.bin / name).chmod(0o700)
        for source, name in (("mash-update-processes.c", "mash-update-processes"), ("mash-update-swap.c", "mash-update-swap")):
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-Wall", "-Wextra", "-Werror", "-O2", "-mmacosx-version-min=14.0", str(ROOT / "packaging/helpers" / source), "-o", str(self.bin / name)], check=True)
        # Different image UUIDs prove an old image cannot ACK a new target.
        source = self.root / "process.c"
        source.write_text('''#include <unistd.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <stdio.h>
int main(int argc, char **argv) {
 const char *marker = getenv("FIXTURE_LAUNCH_MARKER");
 if (marker) { FILE *f = fopen(marker, "w"); if (!f) return 4; fputs("target", f); fclose(f); return 0; }
 if (argc > 1 && !strcmp(argv[1], "child")) { if (!fork()) { execl("/bin/sleep", "sleep", "60", NULL); return 1; } }
 const char *path = getenv("FIXTURE_SOCKET");
 if (path && argc > 1 && !strcmp(argv[1], "server")) {
  struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) return 2;
  strcpy(addr.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 1)) return 3;
 }
 for (;;) pause();
}\n''')
        for app, version in ((self.app, "9.9.8"), (self.candidate, "9.9.9")):
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            resources = app / "Contents/Resources"
            resources.mkdir()
            (resources / "VERSION").write_text(version + "\n")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.mash", "CFBundleShortVersionString": version, "CFBundleVersion": version, "MashUpdateDataCompatibility": "fixture-v1"}))
            subprocess.run(["xcrun", "clang", str(source), "-Wl,-random_uuid", "-o", str(macos / "mash-terminal")], check=True)
        self.env = {"HOME": str(self.data.parent), "PATH": f"{self.fake}:/usr/bin:/bin:/usr/sbin:/sbin", "CALLS": str(self.calls), "FIXTURE_APP": str(self.app), "FIXTURE_CANDIDATE": str(self.candidate), "TMPDIR": str(self.root), "PYTHONDONTWRITEBYTECODE": "1", "FIXTURE_WORKER_PID": str(os.getpid()), "FIXTURE_COMMON": str(self.bin / "mash-update-common"), "FIXTURE_PROCESS_TOOL": str(self.bin / "mash-update-processes")}
        self.stub("codesign", '''echo "codesign $*" >>"$CALLS"
case "$1" in
-dv) case "$2" in "$FIXTURE_APP") echo TeamIdentifier=TEAM >&2 ;; *) echo "TeamIdentifier=${FAKE_TEAM:-TEAM}" >&2 ;; esac ;;
*) exit "${FAKE_CODESIGN_RC:-0}" ;;
esac''')
        self.stub("spctl", 'echo "spctl $*" >>"$CALLS"; exit "${FAKE_SPCTL_RC:-0}"')
        self.stub("curl", '''echo "curl $*" >>"$CALLS"
[ "${FAKE_DOWNLOAD_RC:-0}" = 0 ] || exit "$FAKE_DOWNLOAD_RC"
while [ "$#" -gt 1 ]; do if [ "$1" = -o ]; then printf dmg >"$2"; break; fi; shift; done''')
        self.stub("hdiutil", '''echo "hdiutil $*" >>"$CALLS"
case "$1" in
attach)
 [ "${FAKE_MOUNT_RC:-0}" = 0 ] || exit "$FAKE_MOUNT_RC"
 while [ "$#" -gt 1 ]; do if [ "$1" = -mountpoint ]; then cp -R "$FIXTURE_CANDIDATE" "$2/Mash.app"; break; fi; shift; done ;;
detach) exit "${FAKE_DETACH_RC:-0}" ;;
esac''')
        self.stub("ditto", 'echo "ditto $*" >>"$CALLS"; [ "${FAKE_COPY_RC:-0}" = 0 ] || exit "$FAKE_COPY_RC"; cp -R "$1" "$2"')
        self.stub("xattr", 'echo xattr >>"$CALLS"')
        self.stub("launchctl", '''echo "launchctl $*" >>"$CALLS"
case "$1" in
print) exit 1 ;;
bootstrap)
  [ "${FAKE_BOOTSTRAP_RC:-0}" = 0 ] || exit "$FAKE_BOOTSTRAP_RC"
  program="$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$3")"
  case "$program" in
  */mash-update-gate)
    data="$(/usr/bin/plutil -extract ProgramArguments.3 raw -o - "$3")"
    attempt="$(/usr/bin/plutil -extract ProgramArguments.4 raw -o - "$3")"
    ;;
  *)
    data="$(/usr/bin/plutil -extract ProgramArguments.6 raw -o - "$3")"
    attempt="$(/usr/bin/plutil -extract ProgramArguments.12 raw -o - "$3")"
    ;;
  esac
  "$FIXTURE_PROCESS_TOOL" locked "$data/local/state/update-mutex" /bin/bash "$FIXTURE_COMMON" "$data" claim "$FIXTURE_WORKER_PID" "$attempt"
  ;;
esac''')
        self.stub("osascript", 'echo "quit $*" >>"$CALLS"; exit "${FAKE_QUIT_RC:-0}"')
        self.stub("open", 'echo "open $*" >>"$CALLS"; exit "${FAKE_OPEN_RC:-0}"')
        self.children = []

    def stub(self, name, body):
        path = self.fake / name
        path.write_text("#!/bin/bash\nset -u\n" + body + "\n")
        path.chmod(0o700)

    def shell(self, script, **extra):
        return subprocess.run(["/bin/bash", "-c", script], env={**self.env, **extra}, text=True, capture_output=True, timeout=25)

    def verify(self, answer="y", **extra):
        return subprocess.run(["/bin/bash", str(self.bin / "mash-update-verify"), str(self.app), "9.9.9", "9.9.8", str(self.data)], input=answer + "\n", env={**self.env, **extra}, text=True, capture_output=True, timeout=30)

    def state(self):
        return plistlib.loads((self.data / "local/state/update-transaction.plist").read_bytes())

    def begin(self):
        result = self.shell(f'source "{self.bin}/mash-update-common"; mash_update_init "{self.data}"; mash_update_begin "{self.app}" 9.9.9 9.9.8 "{self.work}"')
        if result.returncode:
            raise AssertionError(result.stderr + result.stdout)
        return self.state()["id"]

    def change(self, **fields):
        state = self.state()
        state.update({key: str(value) for key, value in fields.items()})
        (self.data / "local/state/update-transaction.plist").write_bytes(plistlib.dumps(state))

    def start(self, path, *args, **extra):
        process = subprocess.Popen([str(path), *map(str, args)], env={**self.env, **extra}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(process)
        return process

    def inspector(self, *args):
        return subprocess.check_output([str(self.bin / "mash-update-processes"), *map(str, args)], text=True).strip()

    def close(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        self.temp.cleanup()
