#ifndef MCP_SWAP_H
#define MCP_SWAP_H

#include <stdint.h>

enum mcp_swap_file_kind {
    MCP_SWAP_OTHER = 0,
    MCP_SWAP_REGULAR = 1,
    MCP_SWAP_DIRECTORY = 2,
    MCP_SWAP_SYMLINK = 3,
};

struct mcp_swap_file_stat {
    uint64_t device;
    uint64_t inode;
    uint64_t size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
    uint64_t links;
    uint32_t mode;
    int32_t kind;
};

struct mcp_swap_child {
    int32_t pid;
    int input;
    int output;
    int error;
};

int mcp_swap_lstat(const char *path, struct mcp_swap_file_stat *result);
int mcp_swap_stat(const char *path, struct mcp_swap_file_stat *result);
int mcp_swap_fstat(int descriptor, struct mcp_swap_file_stat *result);
int mcp_swap_exchange(const char *left, const char *right);
int mcp_swap_rename_noreplace(const char *source, const char *destination);
int mcp_swap_lock_exclusive(int descriptor);
int mcp_swap_unlock(int descriptor);
int mcp_swap_sync_directory(const char *path);
int mcp_swap_spawn(const char *command, const char *arguments, uint64_t arguments_size,
                   const char *environment, uint64_t environment_size,
                   struct mcp_swap_child *child);
int mcp_swap_wait_readable(int output, int error, int timeout_ms, int *ready);
int mcp_swap_wait_child(int32_t pid, int nohang, int *status);
int mcp_swap_write_all_no_sigpipe(int descriptor, const void *bytes, uint64_t size);

#endif
