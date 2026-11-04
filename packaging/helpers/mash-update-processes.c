// macOS process identity and a kernel-owned state mutex. No process-name kills.
#include <errno.h>
#include <dirent.h>
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
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int info(pid_t pid, struct proc_bsdinfo *p) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, p, sizeof(*p)) == sizeof(*p) && p->pbi_uid == getuid() && p->pbi_status != SZOMB;
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
static int boot_id(char *value, size_t size) {
    size_t length = size;
    if (sysctlbyname("kern.bootsessionuuid", value, &length, NULL, 0)) return 1;
    value[size - 1] = 0;
    return 0;
}
static int private_dir(const char *path) {
    struct stat st;
    if (mkdir(path, 0700) && errno != EEXIST) return 1;
    return lstat(path, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || chmod(path, 0700);
}
static int registry_dir(const char *data, char *out, size_t size) {
    struct stat st;
    if (*data != '/' || strchr(data, '\n') || lstat(data, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid()) return 1;
    if (snprintf(out, size, "%s/run", data) >= (int)size || private_dir(out)) return 1;
    if (snprintf(out, size, "%s/run/mash-processes", data) >= (int)size || private_dir(out)) return 1;
    return 0;
}
static int prune_registry(const char *dir, const char *boot) {
    DIR *d = opendir(dir);
    if (!d) return 1;
    struct dirent *entry;
    char path[PATH_MAX], recorded[128];
    while ((entry = readdir(d))) {
        pid_t pid = pid_arg(entry->d_name);
        struct proc_bsdinfo p;
        if (pid < 0) continue;
        if (info(pid, &p)) { continue; }
        if (snprintf(path, sizeof(path), "%s/%s", dir, entry->d_name) >= (int)sizeof(path)) continue;
        int fd = open(path, O_RDONLY | O_NOFOLLOW);
        FILE *f = fd >= 0 ? fdopen(fd, "r") : NULL;
        recorded[0] = 0;
        if (f) { char skip[PATH_MAX]; for (int i = 0; i < 2; i++) if (!fgets(skip, sizeof(skip), f)) break; fgets(recorded, sizeof(recorded), f); fclose(f); }
        else if (fd >= 0) close(fd);
        recorded[strcspn(recorded, "\n")] = 0;
        if (strcmp(recorded, boot)) unlink(path);
    }
    closedir(d);
    return 0;
}
static int registration(const char *data, const char *app, pid_t pid, const char *role) {
    char dir[PATH_MAX], path[PATH_MAX], tmp[PATH_MAX], canonical[PATH_MAX], value[64], boot[128];
    struct proc_bsdinfo p;
    if (pid < 0 || !info(pid, &p) || registry_dir(data, dir, sizeof(dir)) || !realpath(app, canonical) || strchr(canonical, '\n') || boot_id(boot, sizeof(boot))) return 1;
    if (strcmp(role, "setup") && strcmp(role, "runtime") && strcmp(role, "waiter")) return 2;
    if (snprintf(path, sizeof(path), "%s/%d", dir, pid) >= (int)sizeof(path) || snprintf(tmp, sizeof(tmp), "%s/.register-XXXXXX", dir) >= (int)sizeof(tmp)) return 1;
    int fd = mkstemp(tmp);
    if (fd < 0) return 1;
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(tmp); return 1; }
    stamp(&p, value, sizeof(value));
    int failed = fprintf(f, "%s\n%s\n%s\n%s\n", canonical, value, boot, role) < 0;
    failed |= fclose(f) != 0;
    if (failed || rename(tmp, path)) { unlink(tmp); return 1; }
    prune_registry(dir, boot);
    return 0;
}
static int registry_role(const char *data, const char *app, pid_t pid, const struct proc_bsdinfo *p) {
    char path[PATH_MAX], line[PATH_MAX], expected[64], boot[128];
    if (!data || snprintf(path, sizeof(path), "%s/run/mash-processes/%d", data, pid) >= (int)sizeof(path) || boot_id(boot, sizeof(boot))) return 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0) return 0;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid()) { close(fd); return 0; }
    FILE *f = fdopen(fd, "r");
    if (!f) { close(fd); return 0; }
    const char *fields[3] = {app, expected, boot};
    stamp(p, expected, sizeof(expected));
    for (int i = 0; i < 3; i++) {
        if (!fgets(line, sizeof(line), f)) { fclose(f); return 0; }
        line[strcspn(line, "\n")] = 0;
        if (strcmp(line, fields[i])) { fclose(f); return 0; }
    }
    int role = 0;
    if (fgets(line, sizeof(line), f)) {
        if (!strcmp(line, "waiter\n")) role = 2;
        else if (!strcmp(line, "setup\n") || !strcmp(line, "runtime\n")) role = 1;
    }
    fclose(f); return role;
}
static int list(const char *app, const char *data, pid_t root, const char *root_stamp) {
    char canonical[PATH_MAX];
    if (app && !realpath(app, canonical)) return 1;
    app = app ? canonical : NULL;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 1;
    count += 256;
    pid_t *pids = calloc((size_t)count, sizeof(*pids));
    struct proc_bsdinfo *rows = calloc((size_t)count, sizeof(*rows));
    unsigned char *owned = calloc((size_t)count, 1);
    unsigned char *excluded = calloc((size_t)count, 1);
    if (!pids || !rows || !owned || !excluded) { free(pids); free(rows); free(owned); free(excluded); return 1; }
    int n = proc_listallpids(pids, count * (int)sizeof(*pids));
    if (n <= 0 || n >= count) { free(pids); free(rows); free(owned); free(excluded); return 1; }
    size_t len = app ? strlen(app) : 0;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (!info(pids[i], &rows[i])) { pids[i] = 0; continue; }
        if (app && proc_pidpath(pids[i], path, sizeof(path)) > 0 && !strncmp(path, app, len) && path[len] == '/') owned[i] = 1;
        if (app) {
            int role = registry_role(data, app, pids[i], &rows[i]);
            if (role == 1) owned[i] = 1;
            if (role == 2) { excluded[i] = 1; owned[i] = 0; }
        } else if (pids[i] == root) {
            char value[64]; stamp(&rows[i], value, sizeof(value));
            if (!strcmp(value, root_stamp)) owned[i] = 1;
        }
    }
    // ponytail: O(n^2) ancestry closure; process tables are small. Replace with
    // a PID-indexed map if profiling a busy host shows this dominates shutdown.
    int changed;
    do {
        changed = 0;
        for (int i = 0; i < n; i++) if (pids[i]) {
            for (int j = 0; j < n; j++) if (pids[j] && rows[i].pbi_ppid == (uint32_t)pids[j] &&
                (rows[j].pbi_start_tvsec < rows[i].pbi_start_tvsec ||
                 (rows[j].pbi_start_tvsec == rows[i].pbi_start_tvsec && rows[j].pbi_start_tvusec <= rows[i].pbi_start_tvusec))) {
                if (excluded[j] && !excluded[i]) { excluded[i] = 1; owned[i] = 0; changed = 1; }
                else if (owned[j] && !owned[i] && !excluded[i]) { owned[i] = 1; changed = 1; }
            }
        }
    } while (changed);
    for (int i = 0; i < n; i++) if (owned[i] && pids[i] != getpid()) {
        char value[64]; stamp(&rows[i], value, sizeof(value));
        printf("%d %s\n", pids[i], value);
    }
    free(pids); free(rows); free(owned); free(excluded); return 0;
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
    if ((argc == 3 || argc == 4) && !strcmp(argv[1], "list")) return list(argv[2], argc == 4 ? argv[3] : NULL, 0, NULL);
    if (argc == 4 && !strcmp(argv[1], "tree")) return list(NULL, NULL, pid_arg(argv[2]), argv[3]);
    if (argc == 6 && !strcmp(argv[1], "register")) return registration(argv[2], argv[3], pid_arg(argv[4]), argv[5]);
    if (argc == 6 && !strcmp(argv[1], "is-waiter")) {
        struct proc_bsdinfo p;
        pid_t pid = pid_arg(argv[4]); char value[64], app[PATH_MAX];
        if (pid < 0 || !info(pid, &p) || !realpath(argv[3], app)) return 1;
        stamp(&p, value, sizeof(value));
        return strcmp(value, argv[5]) || registry_role(argv[2], app, pid, &p) != 2;
    }
    if (argc >= 4 && (!strcmp(argv[1], "locked") || !strcmp(argv[1], "try-locked"))) {
        int fd = open(argv[2], O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 || flock(fd, LOCK_EX | (!strcmp(argv[1], "try-locked") ? LOCK_NB : 0))) return 1;
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
        if (argc == 5 && !strcmp(argv[1], "owner-alive")) {
            char boot[128];
            return strcmp(value, argv[3]) || boot_id(boot, sizeof(boot)) || strcmp(boot, argv[4]);
        }
        if (argc == 3 && !strcmp(argv[1], "image")) {
            char path[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, path, sizeof(path)) <= 0) return 1;
            puts(path); return 0;
        }
        if (argc == 4 && !strcmp(value, argv[3])) {
            if (!strcmp(argv[1], "alive")) return 0;
            if (!strcmp(argv[1], "term")) return kill(pid, SIGTERM) ? 1 : 0;
        }
    }
    fputs("usage: mash-update-processes now | uuid FILE | list APP [DATA] | tree PID START | stamp/image PID | register DATA APP PID ROLE | is-waiter DATA APP PID START | owner-alive PID START BOOT | alive/term PID START | locked|try-locked FILE COMMAND...\n", stderr);
    return 2;
}
