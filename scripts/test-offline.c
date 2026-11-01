#include "OfflineGuard.h"
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int is_permission_error(void) {
    return errno == EPERM || errno == EACCES;
}

int main(void) {
    if (keyboard_lock_enforce_offline() != 0) {
        fprintf(stderr, "Offline guard failed: %s\n", keyboard_lock_offline_error());
        return 1;
    }
    // Idempotence is required if startup code checks the guard twice.
    if (keyboard_lock_enforce_offline() != 0) {
        fprintf(stderr, "Applying the guard twice failed.\n");
        return 1;
    }

    int socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_fd == -1) {
        if (is_permission_error()) {
            puts("PASS: socket creation blocked by the process restriction.");
            return 0;
        }
        perror("socket");
        return 1;
    }

    // Loopback only: no traffic is sent to a remote host, even if the test fails.
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(9);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = connect(socket_fd, (struct sockaddr *)&address, sizeof(address));
    if (result == 0 || !is_permission_error()) {
        fprintf(stderr, "FAIL: connection not denied by permissions (result=%d, errno=%d).\n",
                result, errno);
        close(socket_fd);
        return 1;
    }
    close(socket_fd);
    puts("PASS: outbound socket connection denied with EPERM/EACCES.");

    socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_fd == -1) {
        perror("socket");
        return 1;
    }
    address.sin_port = 0;
    result = bind(socket_fd, (struct sockaddr *)&address, sizeof(address));
    if (result == 0) {
        result = listen(socket_fd, 1);
    }
    if (result == 0 || !is_permission_error()) {
        fprintf(stderr, "FAIL: inbound listener not denied by permissions (result=%d, errno=%d).\n",
                result, errno);
        close(socket_fd);
        return 1;
    }
    close(socket_fd);
    puts("PASS: inbound listener denied with EPERM/EACCES.");
    return 0;
}
