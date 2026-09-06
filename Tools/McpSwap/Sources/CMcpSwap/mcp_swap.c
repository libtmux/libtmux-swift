#define _GNU_SOURCE

#include "mcp_swap.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__linux__)
#include <linux/fs.h>
#include <sys/syscall.h>
#elif defined(__APPLE__)
#include <stdio.h>
#endif

static void copy_stat(const struct stat *source, struct mcp_swap_file_stat *result) {
    result->device = (uint64_t)source->st_dev;
    result->inode = (uint64_t)source->st_ino;
    result->size = (uint64_t)source->st_size;
#if defined(__APPLE__)
    result->modified_seconds = source->st_mtimespec.tv_sec;
    result->modified_nanoseconds = source->st_mtimespec.tv_nsec;
#else
    result->modified_seconds = source->st_mtim.tv_sec;
    result->modified_nanoseconds = source->st_mtim.tv_nsec;
#endif
    result->links = (uint64_t)source->st_nlink;
    result->mode = (uint32_t)(source->st_mode & 07777);
    if (S_ISREG(source->st_mode)) {
        result->kind = MCP_SWAP_REGULAR;
    } else if (S_ISDIR(source->st_mode)) {
        result->kind = MCP_SWAP_DIRECTORY;
    } else if (S_ISLNK(source->st_mode)) {
        result->kind = MCP_SWAP_SYMLINK;
    } else {
        result->kind = MCP_SWAP_OTHER;
    }
}

int mcp_swap_lstat(const char *path, struct mcp_swap_file_stat *result) {
    struct stat value;
    if (lstat(path, &value) != 0) {
        return -1;
    }
    copy_stat(&value, result);
    return 0;
}

int mcp_swap_stat(const char *path, struct mcp_swap_file_stat *result) {
    struct stat value;
    if (stat(path, &value) != 0) {
        return -1;
    }
    copy_stat(&value, result);
    return 0;
}

int mcp_swap_fstat(int descriptor, struct mcp_swap_file_stat *result) {
    struct stat value;
    if (fstat(descriptor, &value) != 0) {
        return -1;
    }
    copy_stat(&value, result);
    return 0;
}

int mcp_swap_exchange(const char *left, const char *right) {
#if defined(__linux__)
    return (int)syscall(SYS_renameat2, AT_FDCWD, left, AT_FDCWD, right, RENAME_EXCHANGE);
#elif defined(__APPLE__)
    return renamex_np(left, right, RENAME_SWAP);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

int mcp_swap_rename_noreplace(const char *source, const char *destination) {
#if defined(__linux__)
    return (int)syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE);
#elif defined(__APPLE__)
    return renamex_np(source, destination, RENAME_EXCL);
#else
    errno = ENOTSUP;
    return -1;
#endif
}

int mcp_swap_lock_exclusive(int descriptor) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        return -1;
    }
    return lockf(descriptor, F_LOCK, 0);
}

int mcp_swap_unlock(int descriptor) {
    if (lseek(descriptor, 0, SEEK_SET) < 0) {
        return -1;
    }
    return lockf(descriptor, F_ULOCK, 0);
}

int mcp_swap_sync_directory(const char *path) {
    int descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        return -1;
    }
    int result = fsync(descriptor);
    int saved_errno = errno;
    if (close(descriptor) != 0 && result == 0) {
        return -1;
    }
    errno = saved_errno;
    return result;
}

static char **split_nul_list(const char *bytes, uint64_t size, size_t prefix) {
    size_t count = prefix;
    for (uint64_t index = 0; index < size; index++) {
        if (bytes[index] == '\0') {
            count++;
        }
    }
    char **result = calloc(count + 1, sizeof(char *));
    if (result == NULL) {
        return NULL;
    }
    size_t output = prefix;
    for (uint64_t index = 0; index < size;) {
        result[output++] = (char *)(bytes + index);
        while (index < size && bytes[index] != '\0') {
            index++;
        }
        index++;
    }
    return result;
}

static int set_close_on_exec(int descriptor) {
    int flags = fcntl(descriptor, F_GETFD);
    return flags < 0 ? -1 : fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
}

int mcp_swap_spawn(const char *command, const char *arguments, uint64_t arguments_size,
                   const char *environment, uint64_t environment_size,
                   struct mcp_swap_child *child) {
    int input[2] = {-1, -1};
    int output[2] = {-1, -1};
    int error_pipe[2] = {-1, -1};
    char **argv = NULL;
    char **envp = NULL;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_ready = 0;
    int attributes_ready = 0;
    int result = 0;

    if (pipe(input) != 0 || pipe(output) != 0 || pipe(error_pipe) != 0) {
        result = errno;
        goto cleanup;
    }
    int all_descriptors[] = {input[0],  input[1],      output[0],
                             output[1], error_pipe[0], error_pipe[1]};
    for (size_t index = 0; index < sizeof(all_descriptors) / sizeof(int); index++) {
        if (set_close_on_exec(all_descriptors[index]) != 0) {
            result = errno;
            goto cleanup;
        }
    }

    argv = split_nul_list(arguments, arguments_size, 1);
    envp = split_nul_list(environment, environment_size, 0);
    if (argv == NULL || envp == NULL) {
        result = ENOMEM;
        goto cleanup;
    }
    argv[0] = (char *)command;
    result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        goto cleanup;
    }
    actions_ready = 1;
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        goto cleanup;
    }
    attributes_ready = 1;
    result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    if (result != 0) {
        goto cleanup;
    }
    result = posix_spawnattr_setpgroup(&attributes, 0);
    if (result != 0) {
        goto cleanup;
    }
    result = posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(&actions, error_pipe[1], STDERR_FILENO);
    }
    for (size_t index = 0; result == 0 && index < sizeof(all_descriptors) / sizeof(int); index++) {
        result = posix_spawn_file_actions_addclose(&actions, all_descriptors[index]);
    }
    if (result != 0) {
        goto cleanup;
    }

    pid_t pid = 0;
    result = posix_spawnp(&pid, command, &actions, &attributes, argv, envp);
    if (result == 0) {
        close(input[0]);
        input[0] = -1;
        close(output[1]);
        output[1] = -1;
        close(error_pipe[1]);
        error_pipe[1] = -1;
        child->pid = (int32_t)pid;
        child->input = input[1];
        child->output = output[0];
        child->error = error_pipe[0];
        input[1] = output[0] = error_pipe[0] = -1;
    }

cleanup:
    if (actions_ready) {
        posix_spawn_file_actions_destroy(&actions);
    }
    if (attributes_ready) {
        posix_spawnattr_destroy(&attributes);
    }
    free(argv);
    free(envp);
    int descriptors[] = {input[0], input[1], output[0], output[1], error_pipe[0], error_pipe[1]};
    for (size_t index = 0; index < sizeof(descriptors) / sizeof(int); index++) {
        if (descriptors[index] >= 0) {
            close(descriptors[index]);
        }
    }
    if (result != 0) {
        errno = result;
        return -1;
    }
    return 0;
}

int mcp_swap_wait_readable(int output, int error_pipe, int timeout_ms, int *ready) {
    struct pollfd descriptors[2] = {
        {.fd = output, .events = POLLIN | POLLHUP, .revents = 0},
        {.fd = error_pipe, .events = POLLIN | POLLHUP, .revents = 0},
    };
    int result;
    do {
        result = poll(descriptors, 2, timeout_ms);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -1;
    }
    *ready = 0;
    if (descriptors[0].revents != 0) {
        *ready |= 1;
    }
    if (descriptors[1].revents != 0) {
        *ready |= 2;
    }
    return result;
}

int mcp_swap_wait_child(int32_t pid, int nohang, int *status) {
    pid_t result;
    do {
        result = waitpid((pid_t)pid, status, nohang ? WNOHANG : 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -1;
    }
    return result == 0 ? 0 : 1;
}

int mcp_swap_write_all_no_sigpipe(int descriptor, const void *bytes, uint64_t size) {
    sigset_t blocked;
    sigset_t original;
    sigset_t pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int mask_result = pthread_sigmask(SIG_BLOCK, &blocked, &original);
    if (mask_result != 0) {
        errno = mask_result;
        return -1;
    }
    int was_pending = 0;
    if (sigpending(&pending) == 0) {
        was_pending = sigismember(&pending, SIGPIPE);
    }

    const unsigned char *cursor = bytes;
    uint64_t remaining = size;
    int result = 0;
    while (remaining > 0) {
        ssize_t written = write(descriptor, cursor, (size_t)remaining);
        if (written > 0) {
            cursor += written;
            remaining -= (uint64_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            result = -1;
            break;
        }
    }
    int saved_errno = errno;
    if (!was_pending && result != 0 && saved_errno == EPIPE) {
        int generated = 0;
        if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) {
            sigwait(&blocked, &generated);
        }
    }
    pthread_sigmask(SIG_SETMASK, &original, NULL);
    errno = saved_errno;
    return result;
}
