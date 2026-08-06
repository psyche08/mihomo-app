#ifndef MIHOMO_CONTROL_H
#define MIHOMO_CONTROL_H

#include <stddef.h>

// Direct XPC client for the root daemon's control service.
//
// The GUI previously reached the daemon by spawning `mihomoboxctl` for every
// request. Measured, that cost ~6 ms of process start plus ~22 ms of building
// the code-signing requirement and validating the peer — per request — because
// a fresh process pays the framework and plug-in loading every time. Holding
// one connection pays it once.
//
// The privilege boundary is unchanged: this speaks the same protocol over the
// same privileged Mach service, and the daemon still admits a peer only if it
// carries the same signing leaf.

typedef struct mihomo_control_session mihomo_control_session;

enum {
    MIHOMO_CONTROL_OK = 0,
    MIHOMO_CONTROL_UNSIGNED = -1,
    MIHOMO_CONTROL_REQUIREMENT_FAILED = -2,
    MIHOMO_CONTROL_CONNECT_FAILED = -3,
    MIHOMO_CONTROL_SEND_FAILED = -4,
    MIHOMO_CONTROL_INVALID_REPLY = -5,
    MIHOMO_CONTROL_INVALID_ARGUMENT = -6,
};

/// Opens a connection to the daemon, deriving the peer requirement from this
/// process's own signing certificate. Returns NULL on failure.
mihomo_control_session *mihomo_control_open(int *out_error);

void mihomo_control_close(mihomo_control_session *session);

/// Sends one request and waits for the reply.
///
/// On success writes newly allocated buffers to `out_response` / `out_payload`
/// (either may come back NULL with length 0); the caller owns them and must
/// release each with `mihomo_control_free`.
int mihomo_control_send(
    mihomo_control_session *session,
    const unsigned char *request,
    size_t request_length,
    const unsigned char *payload,
    size_t payload_length,
    unsigned char **out_response,
    size_t *out_response_length,
    unsigned char **out_payload,
    size_t *out_payload_length
);

void mihomo_control_free(unsigned char *buffer);

#endif
