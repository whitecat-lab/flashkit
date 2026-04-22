#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ms-sys/inc/fat16.h"
#include "ms-sys/inc/fat32.h"
#include "ms-sys/inc/file.h"

static void print_usage(void)
{
    fprintf(stderr, "usage: freedos-boot-helper write --device <path>\n");
}

int main(int argc, char **argv)
{
    const char *device = NULL;
    int fd;
    FAKE_FD fake;
    FILE *stream;
    int should_write = 0;
    int keep_label = 1;

    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("freedos-boot-helper 1.0");
        return 0;
    }

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "write") == 0) {
            should_write = 1;
            continue;
        }
        if (strcmp(argv[index], "--device") == 0 && (index + 1) < argc) {
            device = argv[++index];
            continue;
        }
        if (strcmp(argv[index], "--replace-label") == 0) {
            keep_label = 0;
            continue;
        }
    }

    if (!should_write || device == NULL) {
        print_usage();
        return 2;
    }

    fd = open(device, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "unable to open %s: %s\n", device, strerror(errno));
        return 1;
    }

    fake._handle = (void *)(intptr_t)fd;
    fake._offset = 0;
    stream = (FILE *)&fake;

    if (is_fat_32_fs(stream)) {
        if (!write_fat_32_fd_br(stream, keep_label)) {
            fprintf(stderr, "failed to write FreeDOS FAT32 boot record to %s\n", device);
            close(fd);
            return 1;
        }
    } else if (is_fat_16_fs(stream)) {
        if (!write_fat_16_fd_br(stream, keep_label)) {
            fprintf(stderr, "failed to write FreeDOS FAT16 boot record to %s\n", device);
            close(fd);
            return 1;
        }
    } else {
        fprintf(stderr, "%s does not look like a FAT16 or FAT32 volume\n", device);
        close(fd);
        return 1;
    }

    fsync(fd);
    close(fd);
    return 0;
}
