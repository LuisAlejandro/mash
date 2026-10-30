/*
 * Mash.app's executable: hands off to the launcher script, packaging/mash.
 *
 * Why this is compiled. macOS checks a microphone (or camera) request against
 * the app it holds responsible -- here Mash.app, whose executable started the
 * terminal that every pane and Pi run under. Under the hardened runtime that
 * executable must carry com.apple.security.device.audio-input, or tccd refuses
 * without prompting and CoreAudio delivers a silent stream: dictation reports
 * "no speech detected". A code signature can embed entitlements only in a
 * Mach-O, so while CFBundleExecutable was the shell script itself, Mash.app
 * carried no entitlements no matter what entitlements.plist said.
 *
 * Proven with signed probe apps before this change: a script executable was
 * refused exactly as Mash was, and a compiled executable that execs the same
 * script, then `open`s the nested app, prompted and was granted.
 *
 * All launch logic stays in the script, at Contents/Resources/bin/mash-launch.
 */
#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) {
        fprintf(stderr, "mash: executable path is longer than PATH_MAX\n");
        return 1;
    }
    char joined[PATH_MAX];
    char script[PATH_MAX];
    /* Contents/MacOS/mash -> Contents/Resources/bin/mash-launch. realpath also
       removes the "..": Launch Services rejects a non-canonical bundle path,
       and the script derives the bundle root from its own location. */
    if (snprintf(joined, sizeof joined, "%s/../Resources/bin/mash-launch",
                 dirname(exe)) >= (int)sizeof joined ||
        realpath(joined, script) == NULL) {
        perror("mash: cannot find Contents/Resources/bin/mash-launch");
        return 1;
    }
    argv[0] = script;
    execv(script, argv);
    perror("mash: cannot run Contents/Resources/bin/mash-launch");
    return 1;
}
