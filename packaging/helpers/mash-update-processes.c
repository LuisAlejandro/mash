// macOS process identity and a kernel-owned state mutex. No process-name kills.
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int info(pid_t pid, struct proc_bsdinfo *p) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, p, sizeof(*p)) == sizeof(*p) && p->pbi_uid == getuid();
}
static pid_t pid_arg(const char *s) {
    char *end; errno = 0;
    long n = strtol(s, &end, 10);
    return !errno && *s && !*end && n > 1 && n <= INT32_MAX ? (pid_t)n : -1;
}
static void stamp(const struct proc_bsdinfo *p, char *out, size_t size) {
    snprintf(out, size, "%llu.%06llu", (unsigned long long)p->pbi_start_tvsec, (unsigned long long)p->pbi_start_tvusec);
}
static int uuid(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < (off_t)sizeof(struct mach_header_64)) { if (fd >= 0) close(fd); return 1; }
    size_t size = (size_t)st.st_size;
    const unsigned char *base = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return 1;
    size_t offset = 0, length = size;
    const struct fat_header *fat = (const void *)base;
    if (fat->magic == FAT_CIGAM) {
        uint32_t count = OSSwapBigToHostInt32(fat->nfat_arch);
        if (count > (size - sizeof(*fat)) / sizeof(struct fat_arch)) goto bad;
        const struct fat_arch *arch = (const void *)(base + sizeof(*fat));
        int found = 0;
        for (uint32_t i = 0; i < count; i++) {
            if (OSSwapBigToHostInt32(arch[i].cputype) == CPU_TYPE_ARM64) {
                offset = OSSwapBigToHostInt32(arch[i].offset);
                length = OSSwapBigToHostInt32(arch[i].size);
                found = 1; break;
            }
        }
        if (!found) goto bad;
    }
    if (offset > size || length > size - offset || length < sizeof(struct mach_header_64)) goto bad;
    const struct mach_header_64 *header = (const void *)(base + offset);
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 || header->sizeofcmds > length - sizeof(*header)) goto bad;
    size_t pos = offset + sizeof(*header), end = pos + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (pos > end || end - pos < sizeof(struct load_command)) goto bad;
        const struct load_command *cmd = (const void *)(base + pos);
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > end - pos) goto bad;
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *u = (const void *)cmd;
            for (int j = 0; j < 16; j++) printf("%02X", u->uuid[j]);
            putchar('\n'); munmap((void *)base, size); return 0;
        }
        pos += cmd->cmdsize;
    }
bad:
    munmap((void *)base, size); return 1;
}
static int list(const char *app) {
    char canonical[PATH_MAX];
    if (!realpath(app, canonical)) return 1;
    app = canonical;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 1;
    count += 256;
    pid_t *pids = calloc((size_t)count, sizeof(*pids));
    struct proc_bsdinfo *rows = calloc((size_t)count, sizeof(*rows));
    unsigned char *owned = calloc((size_t)count, 1);
    if (!pids || !rows || !owned) { free(pids); free(rows); free(owned); return 1; }
    int n = proc_listallpids(pids, count * (int)sizeof(*pids));
    if (n <= 0 || n >= count) { free(pids); free(rows); free(owned); return 1; }
    size_t len = strlen(app);
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (!info(pids[i], &rows[i])) { pids[i] = 0; continue; }
        if (proc_pidpath(pids[i], path, sizeof(path)) > 0 && !strncmp(path, app, len) && path[len] == '/') owned[i] = 1;
    }
    // ponytail: O(n^2) ancestry closure; process tables are small. Replace with
    // a PID-indexed map if profiling a busy host shows this dominates shutdown.
    int changed;
    do {
        changed = 0;
        for (int i = 0; i < n; i++) if (pids[i] && !owned[i]) {
            for (int j = 0; j < n; j++) if (owned[j] && rows[i].pbi_ppid == (uint32_t)pids[j]) { owned[i] = 1; changed = 1; break; }
        }
    } while (changed);
    for (int i = 0; i < n; i++) if (owned[i] && pids[i] != getpid()) {
        char value[64]; stamp(&rows[i], value, sizeof(value));
        printf("%d %s\n", pids[i], value);
    }
    free(pids); free(rows); free(owned); return 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "boot")) {
        char value[128]; size_t size = sizeof(value);
        if (sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0)) return 1;
        value[sizeof(value) - 1] = 0;
        puts(value); return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "now")) {
        struct timespec t;
        if (clock_gettime(CLOCK_MONOTONIC, &t)) return 1;
        printf("%lld\n", (long long)t.tv_sec); return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "uuid")) return uuid(argv[2]);
    if (argc == 3 && !strcmp(argv[1], "list")) return list(argv[2]);
    if (argc >= 4 && !strcmp(argv[1], "locked")) {
        int fd = open(argv[2], O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 || flock(fd, LOCK_EX)) return 1;
        pid_t child = fork();
        if (child < 0) return 1;
        if (!child) { execv(argv[3], argv + 3); _exit(127); }
        int status;
        while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 1;
        close(fd);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    if (argc >= 3) {
        struct proc_bsdinfo p;
        pid_t pid = pid_arg(argv[2]);
        if (pid < 0 || !info(pid, &p)) return 1;
        char value[64]; stamp(&p, value, sizeof(value));
        if (argc == 3 && !strcmp(argv[1], "stamp")) { puts(value); return 0; }
        if (argc == 3 && !strcmp(argv[1], "image")) {
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, path, sizeof(path)) <= 0) return 1;
            puts(path); return 0;
        }
        if (argc == 3 && !strcmp(argv[1], "runtime-uuid")) {
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, path, sizeof(path)) <= 0) return 1;
            // The native GUI reports its in-memory LC_UUID as well. Reading
            // this path is only a cross-check, not the source of its ACK.
            return uuid(path);
        }
        if (argc == 4 && !strcmp(value, argv[3])) {
            if (!strcmp(argv[1], "alive")) return 0;
            if (!strcmp(argv[1], "term")) return kill(pid, SIGTERM) ? 1 : 0;
        }
    }
    fputs("usage: mash-update-processes now | uuid FILE | list APP | stamp/image/runtime-uuid PID | alive/term PID START | locked FILE COMMAND...\n", stderr);
    return 2;
}
