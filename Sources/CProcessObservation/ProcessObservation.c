#include "CProcessObservation.h"
#include <errno.h>

#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#endif

int libtmux_open_process(int process) {
#if defined(__linux__) && defined(SYS_pidfd_open)
    return (int)syscall(SYS_pidfd_open, process, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}
