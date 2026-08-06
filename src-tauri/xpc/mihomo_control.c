#include "mihomo_control.h"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

static const char *kServiceName = "dev.linsheng.mihomo.daemon.control";

struct mihomo_control_session {
    xpc_connection_t connection;
};

/// Builds the same requirement string the Swift client builds: this process's
/// own leaf certificate, pinned by SHA-1. Both ends derive it from themselves,
/// so every component signed with one identity admits the others and nothing
/// else does.
static char *copy_signing_requirement(void) {
    SecCodeRef self_code = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self_code) != errSecSuccess || self_code == NULL) {
        return NULL;
    }
    SecStaticCodeRef static_code = NULL;
    OSStatus status = SecCodeCopyStaticCode(self_code, kSecCSDefaultFlags, &static_code);
    CFRelease(self_code);
    if (status != errSecSuccess || static_code == NULL) {
        return NULL;
    }
    CFDictionaryRef information = NULL;
    status = SecCodeCopySigningInformation(static_code, kSecCSSigningInformation, &information);
    CFRelease(static_code);
    if (status != errSecSuccess || information == NULL) {
        return NULL;
    }
    char *requirement = NULL;
    CFArrayRef certificates = CFDictionaryGetValue(information, kSecCodeInfoCertificates);
    if (certificates != NULL && CFArrayGetCount(certificates) > 0) {
        SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0);
        CFDataRef encoded = SecCertificateCopyData(leaf);
        if (encoded != NULL) {
            unsigned char digest[CC_SHA1_DIGEST_LENGTH];
            CC_SHA1(CFDataGetBytePtr(encoded), (CC_LONG)CFDataGetLength(encoded), digest);
            char hexadecimal[CC_SHA1_DIGEST_LENGTH * 2 + 1];
            for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
                snprintf(hexadecimal + i * 2, 3, "%02x", digest[i]);
            }
            size_t size = 64 + sizeof(hexadecimal);
            requirement = malloc(size);
            if (requirement != NULL) {
                snprintf(
                    requirement,
                    size,
                    "anchor apple generic and certificate leaf = H\"%s\"",
                    hexadecimal
                );
            }
            CFRelease(encoded);
        }
    }
    CFRelease(information);
    return requirement;
}

mihomo_control_session *mihomo_control_open(int *out_error) {
    int error = MIHOMO_CONTROL_OK;
    char *requirement = copy_signing_requirement();
    if (requirement == NULL) {
        error = MIHOMO_CONTROL_UNSIGNED;
        goto failed;
    }

    xpc_connection_t connection = xpc_connection_create_mach_service(
        kServiceName,
        NULL,
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED
    );
    if (connection == NULL) {
        error = MIHOMO_CONTROL_CONNECT_FAILED;
        free(requirement);
        goto failed;
    }
    if (xpc_connection_set_peer_code_signing_requirement(connection, requirement) != 0) {
        error = MIHOMO_CONTROL_REQUIREMENT_FAILED;
        free(requirement);
        xpc_connection_cancel(connection);
        xpc_release(connection);
        goto failed;
    }
    free(requirement);

    // Errors surface on the reply of whichever send is in flight, so the
    // handler only has to exist.
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);

    mihomo_control_session *session = calloc(1, sizeof(mihomo_control_session));
    if (session == NULL) {
        error = MIHOMO_CONTROL_CONNECT_FAILED;
        xpc_connection_cancel(connection);
        xpc_release(connection);
        goto failed;
    }
    session->connection = connection;
    if (out_error != NULL) {
        *out_error = MIHOMO_CONTROL_OK;
    }
    return session;

failed:
    if (out_error != NULL) {
        *out_error = error;
    }
    return NULL;
}

void mihomo_control_close(mihomo_control_session *session) {
    if (session == NULL) {
        return;
    }
    if (session->connection != NULL) {
        xpc_connection_cancel(session->connection);
        xpc_release(session->connection);
    }
    free(session);
}

static unsigned char *copy_reply_data(xpc_object_t reply, const char *key, size_t *out_length) {
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(reply, key, &length);
    if (bytes == NULL || length == 0) {
        *out_length = 0;
        return NULL;
    }
    unsigned char *copy = malloc(length);
    if (copy == NULL) {
        *out_length = 0;
        return NULL;
    }
    memcpy(copy, bytes, length);
    *out_length = length;
    return copy;
}

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
) {
    if (session == NULL || session->connection == NULL || request == NULL || request_length == 0 ||
        out_response == NULL || out_response_length == NULL || out_payload == NULL ||
        out_payload_length == NULL) {
        return MIHOMO_CONTROL_INVALID_ARGUMENT;
    }
    *out_response = NULL;
    *out_response_length = 0;
    *out_payload = NULL;
    *out_payload_length = 0;

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    if (message == NULL) {
        return MIHOMO_CONTROL_SEND_FAILED;
    }
    xpc_dictionary_set_data(message, "request", request, request_length);
    if (payload != NULL && payload_length > 0) {
        xpc_dictionary_set_data(message, "payload", payload, payload_length);
    }

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(session->connection, message);
    xpc_release(message);
    if (reply == NULL) {
        return MIHOMO_CONTROL_SEND_FAILED;
    }
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        xpc_release(reply);
        return MIHOMO_CONTROL_SEND_FAILED;
    }

    *out_response = copy_reply_data(reply, "response", out_response_length);
    if (*out_response == NULL) {
        xpc_release(reply);
        return MIHOMO_CONTROL_INVALID_REPLY;
    }
    *out_payload = copy_reply_data(reply, "payload", out_payload_length);
    xpc_release(reply);
    return MIHOMO_CONTROL_OK;
}

void mihomo_control_free(unsigned char *buffer) {
    free(buffer);
}
