#include "OfflineGuard.h"
#include <sandbox.h>
#include <stdio.h>

static int restriction_applied = 0;
static char last_error[1024] = {0};

int keyboard_lock_enforce_offline(void) {
    if (restriction_applied) {
        return 0;
    }

    // A custom Seatbelt profile preserves the accessibility/event-tap APIs,
    // which are incompatible with App Sandbox, while denying all network
    // operations (inbound, outbound and local sockets). This restriction is
    // inherited by children and cannot be removed by this process.
    //
    // sandbox_init is a deprecated compatibility API. If macOS stops accepting
    // this profile, the caller MUST exit rather than run without the guard.
    static const char *profile =
        "(version 1)\n"
        "(allow default)\n"
        "(deny network*)\n";

    char *error = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result = sandbox_init(profile, 0, &error);
    if (result != 0) {
        snprintf(last_error, sizeof(last_error), "%s",
                 error ? error : "macOS could not apply the offline restriction.");
    }
    if (error) {
        sandbox_free_error(error);
    }
#pragma clang diagnostic pop

    if (result != 0) {
        return -1;
    }
    restriction_applied = 1;
    last_error[0] = '\0';
    return 0;
}

const char *keyboard_lock_offline_error(void) {
    return last_error;
}
