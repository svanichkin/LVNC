#include "clvnc.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <copyfile.h>
#include <sys/clonefile.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int fill_addr(struct sockaddr_un *addr, const char *path) {
    if (strlen(path) >= sizeof(addr->sun_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    strncpy(addr->sun_path, path, sizeof(addr->sun_path) - 1);
    return 0;
}

static void no_sigpipe(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
}

int lvnc_unix_listen(const char *path, int backlog) {
    struct sockaddr_un addr;
    if (fill_addr(&addr, path) < 0)
        return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    unlink(path); /* stale socket from a previous run; fails harmlessly if not ours */
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        chmod(path, 0666) < 0 ||
        listen(fd, backlog) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

int lvnc_unix_connect(const char *path) {
    struct sockaddr_un addr;
    if (fill_addr(&addr, path) < 0)
        return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    no_sigpipe(fd);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

int lvnc_peer_uid(int sock, uid_t *uid) {
    gid_t gid;
    return getpeereid(sock, uid, &gid);
}

int lvnc_send_fd(int sock, int fd, const void *data, size_t len) {
    struct iovec iov = { (void *)data, len };
    union {
        struct cmsghdr hdr;
        char buf[CMSG_SPACE(sizeof(int))];
    } ctrl;
    memset(&ctrl, 0, sizeof(ctrl));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.buf;
    msg.msg_controllen = sizeof(ctrl.buf);

    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));

    ssize_t n;
    do {
        n = sendmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    return n == (ssize_t)len ? 0 : -1;
}

ssize_t lvnc_recv_fd(int sock, void *data, size_t len, int *fd_out) {
    *fd_out = -1;
    struct iovec iov = { data, len };
    union {
        struct cmsghdr hdr;
        char buf[CMSG_SPACE(sizeof(int))];
    } ctrl;

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.buf;
    msg.msg_controllen = sizeof(ctrl.buf);

    ssize_t n;
    do {
        n = recvmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    if (n <= 0)
        return n;

    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            memcpy(fd_out, CMSG_DATA(c), sizeof(int));
            break;
        }
    }
    return n;
}

int lvnc_send_with_fds(int sock, const void *data, size_t len, const int *fds, int nfds) {
    if (nfds < 0 || nfds > LVNC_MAX_FDS) {
        errno = EINVAL;
        return -1;
    }
    const char *p = data;
    size_t left = len;

    if (nfds > 0) {
        union {
            struct cmsghdr hdr;
            char buf[CMSG_SPACE(sizeof(int) * LVNC_MAX_FDS)];
        } ctrl;
        memset(&ctrl, 0, sizeof(ctrl));
        struct iovec iov = { (void *)p, left };
        struct msghdr msg;
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = ctrl.buf;
        msg.msg_controllen = (socklen_t)CMSG_SPACE(sizeof(int) * nfds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * nfds);

        ssize_t n;
        do {
            n = sendmsg(sock, &msg, 0);
        } while (n < 0 && errno == EINTR);
        if (n < 0)
            return -1;
        p += n;
        left -= (size_t)n;
    }

    while (left > 0) {
        ssize_t n = write(sock, p, left);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += n;
        left -= (size_t)n;
    }
    return 0;
}

ssize_t lvnc_recv_with_fds(int sock, void *data, size_t len, int *fds, int *nfds) {
    *nfds = 0;
    union {
        struct cmsghdr hdr;
        char buf[CMSG_SPACE(sizeof(int) * LVNC_MAX_FDS)];
    } ctrl;
    struct iovec iov = { data, len };
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.buf;
    msg.msg_controllen = sizeof(ctrl.buf);

    ssize_t n;
    do {
        n = recvmsg(sock, &msg, 0);
    } while (n < 0 && errno == EINTR);
    if (n <= 0)
        return n;

    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue;
        int count = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        for (int i = 0; i < count; i++) {
            int fd;
            memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
            if (*nfds < LVNC_MAX_FDS)
                fds[(*nfds)++] = fd;
            else
                close(fd);
        }
    }
    return n;
}

int lvnc_clone_fd_to(int srcfd, const char *dst) {
    if (fclonefileat(srcfd, AT_FDCWD, dst, 0) == 0)
        return 0;

    /* Different volume or no clone support: copy the data. */
    int out = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out < 0)
        return -1;
    int rc = fcopyfile(srcfd, out, NULL, COPYFILE_DATA);
    int e = errno;
    close(out);
    if (rc != 0) {
        unlink(dst);
        errno = e;
        return -1;
    }
    return 0;
}

int lvnc_shm_create(size_t size) {
    char name[32]; /* PSHMNAMLEN is 31 on macOS */
    for (int attempt = 0; attempt < 16; attempt++) {
        snprintf(name, sizeof(name), "/lvnc.%d.%08x", (int)getpid(), arc4random());
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0) {
            if (errno == EEXIST)
                continue;
            return -1;
        }
        shm_unlink(name);
        if (ftruncate(fd, (off_t)size) < 0) {
            int e = errno;
            close(fd);
            errno = e;
            return -1;
        }
        return fd;
    }
    errno = EEXIST;
    return -1;
}
