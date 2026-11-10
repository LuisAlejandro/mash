// Determinate update window. Executed only from a copy outside Mash.app:
// an image under the bundle is counted as Mash and blocks the swap, and a
// child of the app dies when the app quits. The parent prints the detached
// pid and exits; the child holds the progress lock and polls a status file
// the shell rewrites, so a later worker adopts the same window by writing.
#import <AppKit/AppKit.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    char mode[32];
    char label[512];
    long long done, total, fraction;
} ProgressStatus;

static int lock_fd = -1;
static const char *status_path;

static void trim(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ')) s[--n] = 0;
}

static int read_status(const char *path, ProgressStatus *out) {
    FILE *f = fopen(path, "r");
    char line[640];
    if (!f) return 1;
    memset(out, 0, sizeof(*out));
    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (!strncmp(line, "mode ", 5)) snprintf(out->mode, sizeof(out->mode), "%s", line + 5);
        else if (!strncmp(line, "label ", 6)) snprintf(out->label, sizeof(out->label), "%s", line + 6);
        else if (!strncmp(line, "done ", 5)) out->done = atoll(line + 5);
        else if (!strncmp(line, "total ", 6)) out->total = atoll(line + 6);
        else if (!strncmp(line, "fraction ", 9)) out->fraction = atoll(line + 9);
    }
    fclose(f);
    if (strcmp(out->mode, "bytes") && strcmp(out->mode, "fraction") &&
        strcmp(out->mode, "indeterminate") && strcmp(out->mode, "close")) return 1;
    if (out->done < 0 || out->total < 0 || out->fraction < 0 || out->fraction > 1000) return 1;
    return 0;
}

static int check_status(const char *path) {
    ProgressStatus s;
    if (read_status(path, &s)) return 1;
    printf("mode=%s fraction=%lld done=%lld total=%lld label=%s\n",
           s.mode, s.fraction, s.done, s.total, s.label);
    return 0;
}

static NSString *format_bytes(long long n) {
    if (n < 1000000) return [NSString stringWithFormat:@"%.0f KB", n / 1000.0];
    return [NSString stringWithFormat:@"%.1f MB", n / 1000000.0];
}

@interface MashProgress : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSTextField *detail;
@property(nonatomic, strong) NSProgressIndicator *bar;
@property(nonatomic, assign) BOOL spinning;
@end

@implementation MashProgress
- (void)hide:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    (void)window;
    [NSApp terminate:nil];
    return NO;
}
- (void)apply:(const ProgressStatus *)status {
    if (!strcmp(status->mode, "close")) {
        [NSApp terminate:nil];
        return;
    }
    self.label.stringValue = status->label[0] ? [NSString stringWithUTF8String:status->label] : @"Updating Mash";
    if (status->total > 0) {
        self.detail.hidden = NO;
        self.detail.stringValue = [NSString stringWithFormat:@"%@ of %@", format_bytes(status->done), format_bytes(status->total)];
    } else {
        self.detail.hidden = YES;
    }
    BOOL spin = !strcmp(status->mode, "indeterminate");
    if (spin != self.spinning) {
        self.bar.indeterminate = spin;
        if (spin) [self.bar startAnimation:nil];
        else [self.bar stopAnimation:nil];
        self.spinning = spin;
    }
    if (!spin) self.bar.doubleValue = status->fraction / 10.0;
}
- (void)poll:(NSTimer *)timer {
    (void)timer;
    ProgressStatus status;
    if (read_status(status_path, &status)) return;
    [self apply:&status];
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    NSRect frame = NSMakeRect(0, 0, 440, 132);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    NSWindow *window = self.window;
    window.title = @"Updating Mash";
    window.level = NSFloatingWindowLevel;
    window.delegate = self;
    NSView *content = window.contentView;
    self.label = [NSTextField labelWithString:@"Updating Mash"];
    self.label.translatesAutoresizingMaskIntoConstraints = YES;
    self.label.frame = NSMakeRect(20, 78, 400, 36);
    self.label.font = [NSFont systemFontOfSize:13];
    self.label.maximumNumberOfLines = 2;
    self.detail = [NSTextField labelWithString:@""];
    self.detail.translatesAutoresizingMaskIntoConstraints = YES;
    self.detail.frame = NSMakeRect(20, 58, 400, 16);
    self.detail.font = [NSFont systemFontOfSize:11];
    self.detail.textColor = NSColor.secondaryLabelColor;
    self.bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 36, 400, 16)];
    self.bar.translatesAutoresizingMaskIntoConstraints = YES;
    self.bar.style = NSProgressIndicatorStyleBar;
    self.bar.indeterminate = YES;
    self.bar.minValue = 0;
    self.bar.maxValue = 100;
    [self.bar startAnimation:nil];
    self.spinning = YES;
    NSButton *hide = [NSButton buttonWithTitle:@"Hide" target:self action:@selector(hide:)];
    hide.translatesAutoresizingMaskIntoConstraints = YES;
    hide.frame = NSMakeRect(344, 8, 76, 24);
    hide.bezelStyle = NSBezelStyleRounded;
    [content addSubview:self.label];
    [content addSubview:self.detail];
    [content addSubview:self.bar];
    [content addSubview:hide];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [self poll:nil];
}
@end

// The caller is a Mash pane or the install worker. Anything it still has open
// (the Herdr socket, a script inside the bundle, its current directory) would
// otherwise stay open here for the whole update and can fail shutdown after
// Mash has already quit.
static void close_extra_fds(int keep) {
    int pass, n, i, self, extras[128];
    for (pass = 0; pass < 8; pass++) {
        DIR *dir = opendir("/dev/fd");
        struct dirent *entry;
        if (!dir) return;
        self = dirfd(dir);
        n = 0;
        while ((entry = readdir(dir)) && n < 128) {
            char *end = NULL;
            long fd = strtol(entry->d_name, &end, 10);
            if (end == entry->d_name || *end || fd <= 2 || fd == keep || fd == self) continue;
            extras[n++] = (int)fd;
        }
        closedir(dir);
        if (n == 0) return;
        for (i = 0; i < n; i++) close(extras[i]);
    }
}

static void detach_from_caller(int keep) {
    sigset_t unblock;
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (devnull > 2 && devnull != keep) close(devnull);
    }
    close_extra_fds(keep);
    sigemptyset(&unblock);
    sigaddset(&unblock, SIGTERM);
    sigprocmask(SIG_UNBLOCK, &unblock, NULL);
    chdir("/");
}

static int serve(const char *status, const char *mutex) {
    struct stat st;
    int fd, busy;
    if (status[0] != '/' || mutex[0] != '/') return 1;
    fd = open(mutex, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        if (fd >= 0) close(fd);
        return 1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        busy = errno == EWOULDBLOCK || errno == EAGAIN;
        close(fd);
        return busy ? 2 : 1;
    }
    if (fd <= 2) {
        int high = fcntl(fd, F_DUPFD, 3);
        if (high < 0) {
            close(fd);
            return 1;
        }
        close(fd);
        fd = high;
    }
    lock_fd = fd;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) {
        printf("%ld\n", (long)child);
        fflush(stdout);
        _exit(0);
    }
    setsid();
    signal(SIGHUP, SIG_IGN);
    detach_from_caller(lock_fd);
    status_path = status;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MashProgress *progress = [MashProgress new];
        NSApp.delegate = progress;
        [NSApp run];
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "check")) return check_status(argv[2]);
    if (argc == 4 && !strcmp(argv[1], "serve")) return serve(argv[2], argv[3]);
    fputs("usage: mash-update-progress check STATUS | serve STATUS MUTEX\n", stderr);
    return 1;
}
