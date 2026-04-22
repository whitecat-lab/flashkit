#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "file.h"

static int descriptor_for(FILE *fp)
{
    return (int)(intptr_t)((FAKE_FD *)fp)->_handle;
}

int contains_data(FILE *fp, uint64_t position, const void *data, uint64_t length)
{
    unsigned char buffer[MAX_DATA_LEN];

    if (length > sizeof(buffer)) {
        return 0;
    }

    if (!read_data(fp, position, buffer, length)) {
        return 0;
    }

    return memcmp(buffer, data, (size_t)length) == 0;
}

int read_data(FILE *fp, uint64_t position, void *data, uint64_t length)
{
    FAKE_FD *fd = (FAKE_FD *)fp;
    off_t offset = (off_t)(fd->_offset + position);
    ssize_t total_read = 0;
    int descriptor = descriptor_for(fp);

    while ((uint64_t)total_read < length) {
        ssize_t count = pread(descriptor, (char *)data + total_read, (size_t)(length - total_read), offset + total_read);
        if (count <= 0) {
            return 0;
        }
        total_read += count;
    }

    return 1;
}

int write_data(FILE *fp, uint64_t position, const void *data, uint64_t length)
{
    FAKE_FD *fd = (FAKE_FD *)fp;
    off_t offset = (off_t)(fd->_offset + position);
    ssize_t total_written = 0;
    int descriptor = descriptor_for(fp);

    while ((uint64_t)total_written < length) {
        ssize_t count = pwrite(descriptor, (const char *)data + total_written, (size_t)(length - total_written), offset + total_written);
        if (count <= 0) {
            return 0;
        }
        total_written += count;
    }

    return 1;
}

int64_t write_sectors(void *handle, uint64_t sectorSize, uint64_t startSector, uint64_t sectorCount, const void *buffer)
{
    off_t offset = (off_t)(startSector * sectorSize);
    size_t bytes = (size_t)(sectorCount * sectorSize);
    ssize_t written = pwrite((int)(intptr_t)handle, buffer, bytes, offset);
    return written < 0 ? -1 : written;
}

int64_t read_sectors(void *handle, uint64_t sectorSize, uint64_t startSector, uint64_t sectorCount, void *buffer)
{
    off_t offset = (off_t)(startSector * sectorSize);
    size_t bytes = (size_t)(sectorCount * sectorSize);
    ssize_t read_count = pread((int)(intptr_t)handle, buffer, bytes, offset);
    return read_count < 0 ? -1 : read_count;
}
