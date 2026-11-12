#ifndef CLVNC_H
#define CLVNC_H

#include <stddef.h>
#include <sys/types.h>

/* Create, bind and listen on a Unix stream socket. Replaces a stale socket file
   (if we may), makes the socket connectable by anyone (auth is by peer uid). */
int lvnc_unix_listen(const char *path, int backlog);

/* Connect to a Unix stream socket. Returns fd or -1 (errno set). */
int lvnc_unix_connect(const char *path);

/* Effective uid of the process on the other end of a connected Unix socket. */
int lvnc_peer_uid(int sock, uid_t *uid);

/* Send `len` bytes with file descriptor `fd` attached (SCM_RIGHTS). 0 on success. */
int lvnc_send_fd(int sock, int fd, const void *data, size_t len);

/* Receive up to `len` bytes and an optional attached fd (-1 if none).
   Returns number of bytes received, 0 on EOF, -1 on error. */
ssize_t lvnc_recv_fd(int sock, void *data, size_t len, int *fd_out);

/* Maximum file descriptors attached to one message. */
#define LVNC_MAX_FDS 128

/* Write all `len` bytes; `nfds` descriptors (may be 0) ride along with the first chunk.
   0 on success, -1 on error (errno set). */
int lvnc_send_with_fds(int sock, const void *data, size_t len, const int *fds, int nfds);

/* Read up to `len` bytes; descriptors that arrive with them are stored in `fds`
   (at most LVNC_MAX_FDS) and their number in `*nfds`.
   Returns bytes read, 0 on EOF, -1 on error. */
ssize_t lvnc_recv_with_fds(int sock, void *data, size_t len, int *fds, int *nfds);

/* Materialize the file behind `srcfd` at `dst` (must not exist): APFS clone when
   possible (instant, no extra space), otherwise a data copy. 0 on success. */
int lvnc_clone_fd_to(int srcfd, const char *dst);

/* Anonymous POSIX shared memory of `size` bytes, mode 0600, already unlinked:
   it can only be reached through the returned fd (or a copy passed via SCM_RIGHTS). */
int lvnc_shm_create(size_t size);

#endif
