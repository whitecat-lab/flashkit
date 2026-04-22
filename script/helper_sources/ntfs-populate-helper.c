#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "attrib.h"
#include "dir.h"
#include "layout.h"
#include "unistr.h"
#include "volume.h"

extern char **environ;

static const char *kVersion = "ntfs-populate-helper 1.0";

static void usage(FILE *stream) {
    fprintf(stream,
        "Usage:\n"
        "  ntfs-populate-helper --version\n"
        "  ntfs-populate-helper copy --device DEVICE --source DIR [--skip-relative-path PATH]\n"
        "  ntfs-populate-helper verify-file --device DEVICE --reference FILE --path PATH\n"
        "  ntfs-populate-helper exists --device DEVICE --path PATH\n");
}

static int join_path(char *buffer, size_t buffer_size, const char *left, const char *right) {
    if (snprintf(buffer, buffer_size, "%s/%s", left, right) >= (int)buffer_size) {
        fprintf(stderr, "Path is too long.\n");
        return -1;
    }
    return 0;
}

static int executable_directory(const char *argv0, char *buffer, size_t buffer_size) {
    char resolved[PATH_MAX];
    if (realpath(argv0, resolved) == NULL) {
        return -1;
    }

    char temp[PATH_MAX];
    strncpy(temp, resolved, sizeof(temp) - 1);
    temp[sizeof(temp) - 1] = '\0';

    char *dir = dirname(temp);
    if (strlen(dir) + 1 > buffer_size) {
        return -1;
    }
    strncpy(buffer, dir, buffer_size - 1);
    buffer[buffer_size - 1] = '\0';
    return 0;
}

static int helper_path(const char *argv0, const char *name, char *buffer, size_t buffer_size) {
    char directory[PATH_MAX];
    if (executable_directory(argv0, directory, sizeof(directory)) != 0) {
        fprintf(stderr, "Unable to resolve helper directory.\n");
        return -1;
    }
    if (join_path(buffer, buffer_size, directory, name) != 0) {
        return -1;
    }
    if (access(buffer, X_OK) != 0) {
        fprintf(stderr, "Missing bundled helper: %s\n", name);
        return -1;
    }
    return 0;
}

static int run_helper_simple(char *const argv[]) {
    pid_t pid = 0;
    int status = 0;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) {
        return -1;
    }
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static int run_ntfscp(const char *ntfscp_path, const char *device, const char *source_path, const char *relative_path) {
    char *const argv[] = {
        (char *)ntfscp_path,
        "-f",
        "-t",
        (char *)device,
        (char *)source_path,
        (char *)relative_path,
        NULL,
    };
    return run_helper_simple(argv);
}

static void emit_progress(int64_t copied_bytes, int64_t total_bytes, const char *relative_path) {
    fprintf(stdout, "FLASHKIT_PROGRESS\t%lld\t%lld\t%s\n", copied_bytes, total_bytes, relative_path);
    fflush(stdout);
}

static int ntfscat_pipe(const char *ntfscat_path, const char *device, const char *relative_path, int *output_fd, pid_t *pid_out) {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    char *const argv[] = {
        (char *)ntfscat_path,
        (char *)device,
        (char *)relative_path,
        NULL,
    };

    pid_t pid = 0;
    int spawn_result = posix_spawn(&pid, ntfscat_path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);

    if (spawn_result != 0) {
        close(pipefd[0]);
        errno = spawn_result;
        return -1;
    }

    *output_fd = pipefd[0];
    *pid_out = pid;
    return 0;
}

static int wait_for_success(pid_t pid) {
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static bool should_skip(const char *relative_path, const char *skip_relative_path) {
    return skip_relative_path != NULL && strcasecmp(relative_path, skip_relative_path) == 0;
}

static int create_directory_path(ntfs_volume *volume, const char *relative_path) {
    if (relative_path == NULL || *relative_path == '\0') {
        return 0;
    }

    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    if (root == NULL) {
        fprintf(stderr, "Unable to open the NTFS root inode.\n");
        return -1;
    }

    ntfs_inode *parent = root;
    char *path_copy = strdup(relative_path);
    if (path_copy == NULL) {
        ntfs_inode_close(root);
        errno = ENOMEM;
        return -1;
    }

    char *save_ptr = NULL;
    char *component = strtok_r(path_copy, "/", &save_ptr);

    while (component != NULL) {
        ntfs_inode *child = ntfs_pathname_to_inode(volume, parent, component);
        if (child == NULL) {
            int name_len = 0;
            ntfschar *name = ntfs_str2ucs(component, &name_len);
            if (name == NULL) {
                free(path_copy);
                if (parent != root) {
                    ntfs_inode_close(parent);
                }
                ntfs_inode_close(root);
                return -1;
            }

            child = ntfs_create(parent, 0, name, (u8)name_len, S_IFDIR);
            ntfs_ucsfree(name);
            if (child == NULL) {
                fprintf(stderr, "Unable to create NTFS directory: %s\n", relative_path);
                free(path_copy);
                if (parent != root) {
                    ntfs_inode_close(parent);
                }
                ntfs_inode_close(root);
                return -1;
            }
        }

        if (parent != root) {
            ntfs_inode_close(parent);
        }
        parent = child;
        component = strtok_r(NULL, "/", &save_ptr);
    }

    if (parent != root) {
        ntfs_inode_close(parent);
    }
    ntfs_inode_close(root);
    free(path_copy);
    return 0;
}

static int walk_directories(const char *source_root, const char *relative_path, ntfs_volume *volume, const char *skip_relative_path) {
    char absolute_path[PATH_MAX];
    if (*relative_path == '\0') {
        strncpy(absolute_path, source_root, sizeof(absolute_path) - 1);
        absolute_path[sizeof(absolute_path) - 1] = '\0';
    } else if (join_path(absolute_path, sizeof(absolute_path), source_root, relative_path) != 0) {
        return -1;
    }

    DIR *directory = opendir(absolute_path);
    if (directory == NULL) {
        fprintf(stderr, "Unable to open source directory: %s\n", absolute_path);
        return -1;
    }

    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 || entry->d_name[0] == '.') {
            continue;
        }

        char child_relative[PATH_MAX];
        if (*relative_path == '\0') {
            strncpy(child_relative, entry->d_name, sizeof(child_relative) - 1);
            child_relative[sizeof(child_relative) - 1] = '\0';
        } else if (join_path(child_relative, sizeof(child_relative), relative_path, entry->d_name) != 0) {
            closedir(directory);
            return -1;
        }

        if (should_skip(child_relative, skip_relative_path)) {
            continue;
        }

        char child_absolute[PATH_MAX];
        if (join_path(child_absolute, sizeof(child_absolute), source_root, child_relative) != 0) {
            closedir(directory);
            return -1;
        }

        struct stat item_stat;
        if (lstat(child_absolute, &item_stat) != 0) {
            closedir(directory);
            return -1;
        }

        if (S_ISDIR(item_stat.st_mode)) {
            if (create_directory_path(volume, child_relative) != 0) {
                closedir(directory);
                return -1;
            }
            if (walk_directories(source_root, child_relative, volume, skip_relative_path) != 0) {
                closedir(directory);
                return -1;
            }
        }
    }

    closedir(directory);
    return 0;
}

static int calculate_total_bytes(const char *source_root, const char *relative_path, const char *skip_relative_path, int64_t *total_bytes) {
    char absolute_path[PATH_MAX];
    if (*relative_path == '\0') {
        strncpy(absolute_path, source_root, sizeof(absolute_path) - 1);
        absolute_path[sizeof(absolute_path) - 1] = '\0';
    } else if (join_path(absolute_path, sizeof(absolute_path), source_root, relative_path) != 0) {
        return -1;
    }

    DIR *directory = opendir(absolute_path);
    if (directory == NULL) {
        fprintf(stderr, "Unable to open source directory: %s\n", absolute_path);
        return -1;
    }

    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 || entry->d_name[0] == '.') {
            continue;
        }

        char child_relative[PATH_MAX];
        if (*relative_path == '\0') {
            strncpy(child_relative, entry->d_name, sizeof(child_relative) - 1);
            child_relative[sizeof(child_relative) - 1] = '\0';
        } else if (join_path(child_relative, sizeof(child_relative), relative_path, entry->d_name) != 0) {
            closedir(directory);
            return -1;
        }

        if (should_skip(child_relative, skip_relative_path)) {
            continue;
        }

        char child_absolute[PATH_MAX];
        if (join_path(child_absolute, sizeof(child_absolute), source_root, child_relative) != 0) {
            closedir(directory);
            return -1;
        }

        struct stat item_stat;
        if (lstat(child_absolute, &item_stat) != 0) {
            closedir(directory);
            return -1;
        }

        if (S_ISDIR(item_stat.st_mode)) {
            if (calculate_total_bytes(source_root, child_relative, skip_relative_path, total_bytes) != 0) {
                closedir(directory);
                return -1;
            }
        } else if (S_ISREG(item_stat.st_mode)) {
            *total_bytes += (int64_t)item_stat.st_size;
        }
    }

    closedir(directory);
    return 0;
}

static int walk_files(
    const char *source_root,
    const char *relative_path,
    const char *device,
    const char *skip_relative_path,
    const char *ntfscp_path,
    int64_t total_bytes,
    int64_t *copied_bytes
) {
    char absolute_path[PATH_MAX];
    if (*relative_path == '\0') {
        strncpy(absolute_path, source_root, sizeof(absolute_path) - 1);
        absolute_path[sizeof(absolute_path) - 1] = '\0';
    } else if (join_path(absolute_path, sizeof(absolute_path), source_root, relative_path) != 0) {
        return -1;
    }

    DIR *directory = opendir(absolute_path);
    if (directory == NULL) {
        fprintf(stderr, "Unable to open source directory: %s\n", absolute_path);
        return -1;
    }

    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 || entry->d_name[0] == '.') {
            continue;
        }

        char child_relative[PATH_MAX];
        if (*relative_path == '\0') {
            strncpy(child_relative, entry->d_name, sizeof(child_relative) - 1);
            child_relative[sizeof(child_relative) - 1] = '\0';
        } else if (join_path(child_relative, sizeof(child_relative), relative_path, entry->d_name) != 0) {
            closedir(directory);
            return -1;
        }

        if (should_skip(child_relative, skip_relative_path)) {
            continue;
        }

        char child_absolute[PATH_MAX];
        if (join_path(child_absolute, sizeof(child_absolute), source_root, child_relative) != 0) {
            closedir(directory);
            return -1;
        }

        struct stat item_stat;
        if (lstat(child_absolute, &item_stat) != 0) {
            closedir(directory);
            return -1;
        }

        if (S_ISDIR(item_stat.st_mode)) {
            if (walk_files(source_root, child_relative, device, skip_relative_path, ntfscp_path, total_bytes, copied_bytes) != 0) {
                closedir(directory);
                return -1;
            }
        } else if (S_ISREG(item_stat.st_mode)) {
            if (run_ntfscp(ntfscp_path, device, child_absolute, child_relative) != 0) {
                fprintf(stderr, "Unable to copy %s into NTFS.\n", child_relative);
                closedir(directory);
                return -1;
            }
            *copied_bytes += (int64_t)item_stat.st_size;
            emit_progress(*copied_bytes, total_bytes, child_relative);
        }
    }

    closedir(directory);
    return 0;
}

static int command_copy(const char *argv0, const char *device, const char *source_root, const char *skip_relative_path) {
    char ntfscp_path[PATH_MAX];
    if (helper_path(argv0, "ntfscp", ntfscp_path, sizeof(ntfscp_path)) != 0) {
        return 1;
    }

    ntfs_set_char_encoding("utf8");
#if defined(__APPLE__) || defined(__DARWIN__)
    ntfs_macosx_normalize_filenames(0);
#endif

    int64_t total_bytes = 0;
    if (calculate_total_bytes(source_root, "", skip_relative_path, &total_bytes) != 0) {
        return 1;
    }

    ntfs_volume *volume = ntfs_mount(device, NTFS_MNT_RECOVER);
    if (volume == NULL) {
        fprintf(stderr, "Unable to mount NTFS volume %s for directory preparation.\n", device);
        return 1;
    }

    if (walk_directories(source_root, "", volume, skip_relative_path) != 0) {
        ntfs_umount(volume, FALSE);
        return 1;
    }

    if (ntfs_umount(volume, FALSE) != 0) {
        fprintf(stderr, "Unable to finalize NTFS directory preparation.\n");
        return 1;
    }

    int64_t copied_bytes = 0;
    if (walk_files(source_root, "", device, skip_relative_path, ntfscp_path, total_bytes, &copied_bytes) != 0) {
        return 1;
    }

    return 0;
}

static int command_verify_file(const char *argv0, const char *device, const char *reference_path, const char *relative_path) {
    char ntfscat_path[PATH_MAX];
    if (helper_path(argv0, "ntfscat", ntfscat_path, sizeof(ntfscat_path)) != 0) {
        return 1;
    }

    int reference_fd = open(reference_path, O_RDONLY);
    if (reference_fd < 0) {
        fprintf(stderr, "Unable to open reference file: %s\n", reference_path);
        return 1;
    }

    int output_fd = -1;
    pid_t pid = 0;
    if (ntfscat_pipe(ntfscat_path, device, relative_path, &output_fd, &pid) != 0) {
        close(reference_fd);
        fprintf(stderr, "Unable to read NTFS path: %s\n", relative_path);
        return 1;
    }

    int exit_code = 0;
    char reference_buffer[1024 * 1024];
    char ntfs_buffer[1024 * 1024];

    while (1) {
        ssize_t reference_read = read(reference_fd, reference_buffer, sizeof(reference_buffer));
        ssize_t ntfs_read = read(output_fd, ntfs_buffer, sizeof(ntfs_buffer));
        if (reference_read < 0 || ntfs_read < 0) {
            exit_code = 1;
            break;
        }
        if (reference_read != ntfs_read) {
            exit_code = 1;
            break;
        }
        if (reference_read == 0) {
            break;
        }
        if (memcmp(reference_buffer, ntfs_buffer, (size_t)reference_read) != 0) {
            exit_code = 1;
            break;
        }
    }

    close(reference_fd);
    close(output_fd);

    if (wait_for_success(pid) != 0) {
        exit_code = 1;
    }

    if (exit_code != 0) {
        fprintf(stderr, "NTFS verification failed for %s.\n", relative_path);
        return 1;
    }
    return 0;
}

static int command_exists(const char *argv0, const char *device, const char *relative_path) {
    char ntfscat_path[PATH_MAX];
    if (helper_path(argv0, "ntfscat", ntfscat_path, sizeof(ntfscat_path)) != 0) {
        return 1;
    }

    int output_fd = -1;
    pid_t pid = 0;
    if (ntfscat_pipe(ntfscat_path, device, relative_path, &output_fd, &pid) != 0) {
        fprintf(stderr, "Missing NTFS path: %s\n", relative_path);
        return 1;
    }

    char buffer[4096];
    while (read(output_fd, buffer, sizeof(buffer)) > 0) {
    }
    close(output_fd);

    if (wait_for_success(pid) != 0) {
        fprintf(stderr, "Missing NTFS path: %s\n", relative_path);
        return 1;
    }
    return 0;
}

static int validate_bundle(const char *argv0) {
    char ntfscp_path[PATH_MAX];
    char ntfscat_path[PATH_MAX];
    if (helper_path(argv0, "ntfscp", ntfscp_path, sizeof(ntfscp_path)) != 0) {
        return 1;
    }
    if (helper_path(argv0, "ntfscat", ntfscat_path, sizeof(ntfscat_path)) != 0) {
        return 1;
    }

    char *const copy_args[] = { ntfscp_path, "--version", NULL };
    char *const cat_args[] = { ntfscat_path, "--version", NULL };
    if (run_helper_simple(copy_args) != 0 || run_helper_simple(cat_args) != 0) {
        fprintf(stderr, "Bundled NTFS utility validation failed.\n");
        return 1;
    }

    fprintf(stdout, "%s\n", kVersion);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(stderr);
        return 1;
    }

    if (strcmp(argv[1], "--version") == 0) {
        return validate_bundle(argv[0]);
    }

    const char *command = argv[1];
    const char *device = NULL;
    const char *source_root = NULL;
    const char *skip_relative_path = NULL;
    const char *reference_path = NULL;
    const char *relative_path = NULL;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            device = argv[++i];
        } else if (strcmp(argv[i], "--source") == 0 && i + 1 < argc) {
            source_root = argv[++i];
        } else if (strcmp(argv[i], "--skip-relative-path") == 0 && i + 1 < argc) {
            skip_relative_path = argv[++i];
        } else if (strcmp(argv[i], "--reference") == 0 && i + 1 < argc) {
            reference_path = argv[++i];
        } else if (strcmp(argv[i], "--path") == 0 && i + 1 < argc) {
            relative_path = argv[++i];
        } else {
            usage(stderr);
            return 1;
        }
    }

    if (strcmp(command, "copy") == 0) {
        if (device == NULL || source_root == NULL) {
            usage(stderr);
            return 1;
        }
        return command_copy(argv[0], device, source_root, skip_relative_path);
    }

    if (strcmp(command, "verify-file") == 0) {
        if (device == NULL || reference_path == NULL || relative_path == NULL) {
            usage(stderr);
            return 1;
        }
        return command_verify_file(argv[0], device, reference_path, relative_path);
    }

    if (strcmp(command, "exists") == 0) {
        if (device == NULL || relative_path == NULL) {
            usage(stderr);
            return 1;
        }
        return command_exists(argv[0], device, relative_path);
    }

    usage(stderr);
    return 1;
}
