#ifndef KEYBOARD_LOCK_OFFLINE_GUARD_H
#define KEYBOARD_LOCK_OFFLINE_GUARD_H

#ifdef __cplusplus
extern "C" {
#endif

/// Apply a permanent, process-local restriction that denies socket networking.
/// Must run on the main thread before creating the application or any workers.
/// Returns 0 on success, -1 on failure. Do not start the app after failure.
int keyboard_lock_enforce_offline(void);

/// A static UTF-8 diagnostic. Empty after success; never NULL.
const char *keyboard_lock_offline_error(void);

#ifdef __cplusplus
}
#endif

#endif
