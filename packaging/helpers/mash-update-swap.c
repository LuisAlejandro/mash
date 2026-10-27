// Atomically exchange two complete application bundles on the same macOS
// volume. Unlike `mv old aside; mv new into place`, RENAME_SWAP has no instant
// at which the installed path is absent. An unsupported filesystem or failed
// syscall leaves both directories in place; the caller must fail closed.
#include <fcntl.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 3) {
    fputs("usage: mash-update-swap NEW_SIBLING INSTALLED_APP\n", stderr);
    return 2;
  }
  if (renameatx_np(AT_FDCWD, argv[1], AT_FDCWD, argv[2], RENAME_SWAP) != 0) {
    perror("mash-update-swap");
    return 1;
  }
  return 0;
}
