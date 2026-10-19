/* Remember physical disconnects even while the importer is busy copying.
 * sysfs poll notifications plus a 100 ms fallback; never touches disk contents.
 * argv: UDC state, mass-storage function directory, runtime marker path.
 */
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) { perror("UDC state"); return 1; }
    char *tmp = malloc(strlen(argv[3]) + 5);
    if (!tmp) return 1;
    sprintf(tmp, "%s.new", argv[3]);
    ino_t connected_inode = 0;
    struct pollfd p = { .fd = fd, .events = POLLPRI | POLLERR };
    for (;;) {
        char state[64] = {0};
        if (lseek(fd, 0, SEEK_SET) < 0) return 1;
        ssize_t n = read(fd, state, sizeof(state)-1);
        if (n < 0) { if (errno == EINTR) continue; return 1; }
        if (!strncmp(state, "configured", 10)) {
            struct stat st;
            if (!stat(argv[2], &st)) connected_inode = st.st_ino;
        } else if (!strncmp(state, "not attached", 12) && connected_inode) {
            FILE *out = fopen(tmp, "w");
            if (!out) return 1;
            int failed = fprintf(out, "%ju\n", (uintmax_t)connected_inode) < 0;
            if (fclose(out)) failed = 1;
            if (failed || rename(tmp, argv[3])) return 1;
            connected_inode = 0;
        }
        if (poll(&p, 1, 100) < 0 && errno != EINTR) return 1;
    }
}
