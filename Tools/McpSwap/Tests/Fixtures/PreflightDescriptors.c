#define _POSIX_C_SOURCE 200809L

#include "mcp_swap.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return -1;
    }
    return value.tv_sec + value.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        return 2;
    }
    int report = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (report < 0) {
        return 2;
    }
    int mask = atoi(argv[1]);
    int result = 1;
    int started = 0;
    struct mcp_swap_child child = {.input = -1, .output = -1, .error = -1};
    char output[64] = {0};
    char errors[64] = {0};
    size_t lengths[2] = {0, 0};
    const char arguments[] = "-c\0IFS= read -r line; printf '%s\\n' \"$line\"; "
                             "printf '%s\\n' diagnostic >&2\0";
    for (int descriptor = 0; descriptor <= STDERR_FILENO; descriptor++) {
        if ((mask & (1 << descriptor)) != 0 && close(descriptor) != 0) {
            goto cleanup;
        }
    }
    if (mcp_swap_spawn("/bin/sh", arguments, sizeof(arguments) - 1, "", 0, &child) != 0) {
        goto cleanup;
    }
    started = 1;
    for (int descriptor = 0; descriptor <= STDERR_FILENO; descriptor++) {
        if ((mask & (1 << descriptor)) != 0 &&
            (fcntl(descriptor, F_GETFD) != -1 || errno != EBADF)) {
            goto cleanup;
        }
    }
    if (mcp_swap_write_all_no_sigpipe(child.input, "hello\n", 6) != 0) {
        goto cleanup;
    }
    close(child.input);
    child.input = -1;
    double began = now();
    if (began < 0) {
        goto cleanup;
    }
    while (child.output >= 0 || child.error >= 0) {
        double current = now();
        if (current < 0 || current - began >= 3) {
            goto cleanup;
        }
        int ready = 0;
        if (mcp_swap_wait_readable(child.output, child.error, 50, &ready) < 0) {
            goto cleanup;
        }
        int *descriptors[] = {&child.output, &child.error};
        char *buffers[] = {output, errors};
        for (int stream = 0; stream < 2; stream++) {
            if ((ready & (1 << stream)) == 0 || *descriptors[stream] < 0) {
                continue;
            }
            ssize_t count =
                read(*descriptors[stream], buffers[stream] + lengths[stream], 63 - lengths[stream]);
            if (count < 0 || lengths[stream] + count >= 63) {
                goto cleanup;
            }
            lengths[stream] += (size_t)count;
            if (count == 0) {
                close(*descriptors[stream]);
                *descriptors[stream] = -1;
            }
        }
    }
    if (child.output >= 0 || child.error >= 0 || strcmp(output, "hello\n") != 0 ||
        strcmp(errors, "diagnostic\n") != 0) {
        goto cleanup;
    }
    result = 0;

cleanup:
    if (started) {
        int status = 0;
        pid_t waited;
        do {
            waited = waitpid(child.pid, &status, WNOHANG);
        } while (waited == -1 && errno == EINTR);
        if (waited == 0) {
            kill(-child.pid, SIGKILL);
            do {
                waited = waitpid(child.pid, &status, 0);
            } while (waited == -1 && errno == EINTR);
        }
        if (waited != child.pid) {
            result = 1;
        }
    }
    if (child.input >= 0) {
        close(child.input);
    }
    if (child.output >= 0) {
        close(child.output);
    }
    if (child.error >= 0) {
        close(child.error);
    }
    dprintf(report, "mask=%d result=%d stdout=%s stderr=%s\n", mask, result, output, errors);
    close(report);
    return result;
}
