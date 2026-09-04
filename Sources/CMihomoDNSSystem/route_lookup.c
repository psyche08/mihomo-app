#include "CMihomoDNSSystem.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <pthread.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

// A routing socket answers the same question `/sbin/route -n get` does, without
// the fork: the consistency observer asks it every two seconds and the daemon
// asks it on every tray poll, which was ~2,500 process spawns an hour — more
// than everything else this app spawns put together.
//
// The socket is opened once and kept. That has one consequence worth stating:
// PF_ROUTE broadcasts every routing change to every open socket, so unrelated
// messages pile up in the receive buffer between our queries. Each lookup
// therefore drains what it finds, matching replies by (pid, seq) and discarding
// the rest, and gives up on a deadline rather than blocking.

static pthread_mutex_t route_lock = PTHREAD_MUTEX_INITIALIZER;
static int route_descriptor = -1;
static int route_sequence = 0;

uint32_t mihomo_dns_route_event_mask_for_type(uint8_t message_type) {
    switch (message_type) {
        case RTM_ADD:
        case RTM_DELETE:
        case RTM_CHANGE:
        case RTM_REDIRECT:
        case RTM_OLDADD:
        case RTM_OLDDEL:
            return MIHOMO_DNS_ROUTE_EVENT_ROUTE;
        case RTM_NEWADDR:
        case RTM_DELADDR:
            return MIHOMO_DNS_ROUTE_EVENT_ADDRESS;
        case RTM_IFINFO:
        case RTM_IFINFO2:
            return MIHOMO_DNS_ROUTE_EVENT_INTERFACE;
        default:
            return 0;
    }
}

int mihomo_dns_route_monitor_open(void) {
    int descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (descriptor < 0) {
        return -errno;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
        int failure = -errno;
        close(descriptor);
        return failure;
    }
    int descriptor_flags = fcntl(descriptor, F_GETFD, 0);
    if (descriptor_flags < 0 ||
        fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        int failure = -errno;
        close(descriptor);
        return failure;
    }
    int buffer = 64 * 1024;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    return descriptor;
}

int mihomo_dns_route_monitor_drain(int descriptor, uint32_t *out_mask) {
    if (descriptor < 0 || out_mask == NULL) {
        return -EINVAL;
    }
    *out_mask = 0;
    unsigned char message[64 * 1024];
    for (;;) {
        ssize_t length = recv(descriptor, message, sizeof(message), 0);
        if (length < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return 0;
            }
            return -errno;
        }
        if (length == 0) {
            return -ECONNRESET;
        }
        if (length < 4) {
            continue;
        }
        // All Darwin routing messages start with msglen, version and type,
        // including if_msghdr and ifa_msghdr variants.
        uint16_t message_length = 0;
        memcpy(&message_length, message, sizeof(message_length));
        if (message_length < 4 || message_length > (size_t)length ||
            message[2] != RTM_VERSION) {
            continue;
        }
        *out_mask |= mihomo_dns_route_event_mask_for_type(message[3]);
    }
}

static void route_close_locked(void) {
    if (route_descriptor >= 0) {
        close(route_descriptor);
        route_descriptor = -1;
    }
}

static int route_socket_locked(void) {
    if (route_descriptor >= 0) {
        return route_descriptor;
    }
    int descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    if (descriptor < 0) {
        return -errno;
    }
    // Non-blocking: a query must never park a caller on a socket that also
    // carries traffic we did not ask for.
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
        int failure = -errno;
        close(descriptor);
        return failure;
    }
    int descriptor_flags = fcntl(descriptor, F_GETFD, 0);
    if (descriptor_flags < 0 ||
        fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        int failure = -errno;
        close(descriptor);
        return failure;
    }
    // Nothing consumes unsolicited messages between queries, so keep the buffer
    // small; the kernel dropping stale broadcasts is the desired outcome.
    int buffer = 8 * 1024;
    setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
    route_descriptor = descriptor;
    return descriptor;
}

static long route_now_milliseconds(void) {
    struct timeval now;
    gettimeofday(&now, NULL);
    return (long)now.tv_sec * 1000 + now.tv_usec / 1000;
}

int mihomo_dns_route_interface(const char *address, char *out_name, size_t out_length) {
    struct in_addr destination;
    if (address == NULL || out_name == NULL || out_length < IF_NAMESIZE ||
        inet_pton(AF_INET, address, &destination) != 1) {
        return -EINVAL;
    }
    out_name[0] = '\0';

    struct {
        struct rt_msghdr header;
        struct sockaddr_in destination;
    } request;
    unsigned char reply[2048];

    pthread_mutex_lock(&route_lock);
    int descriptor = route_socket_locked();
    if (descriptor < 0) {
        pthread_mutex_unlock(&route_lock);
        return descriptor;
    }

    if (++route_sequence <= 0) {
        route_sequence = 1;
    }
    int sequence = route_sequence;
    pid_t self = getpid();

    memset(&request, 0, sizeof(request));
    request.header.rtm_msglen = sizeof(request);
    request.header.rtm_version = RTM_VERSION;
    request.header.rtm_type = RTM_GET;
    // RTA_IFP asks the kernel to name the outgoing interface in the reply,
    // which is the whole point of the lookup.
    request.header.rtm_addrs = RTA_DST | RTA_IFP;
    request.header.rtm_pid = self;
    request.header.rtm_seq = sequence;
    request.destination.sin_len = sizeof(request.destination);
    request.destination.sin_family = AF_INET;
    request.destination.sin_addr = destination;

    if (write(descriptor, &request, sizeof(request)) != (ssize_t)sizeof(request)) {
        int failure = -errno;
        route_close_locked();
        pthread_mutex_unlock(&route_lock);
        return failure;
    }

    int result = -ESRCH;
    long deadline = route_now_milliseconds() + 200;
    for (;;) {
        ssize_t length = read(descriptor, reply, sizeof(reply));
        if (length < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                result = -errno;
                route_close_locked();
                break;
            }
            if (route_now_milliseconds() >= deadline) {
                result = -ETIMEDOUT;
                break;
            }
            usleep(2000);
            continue;
        }
        if (length < (ssize_t)sizeof(struct rt_msghdr)) {
            continue;
        }
        struct rt_msghdr *header = (struct rt_msghdr *)reply;
        // Skip the routing changes the kernel broadcasts to every open socket.
        if (header->rtm_type != RTM_GET || header->rtm_pid != self ||
            header->rtm_seq != sequence) {
            if (route_now_milliseconds() >= deadline) {
                result = -ETIMEDOUT;
                break;
            }
            continue;
        }
        if (header->rtm_errno != 0) {
            result = -header->rtm_errno;
            break;
        }

        // Walk the returned sockaddrs in RTA order and pick out the interface.
        unsigned char *cursor = reply + sizeof(struct rt_msghdr);
        unsigned char *end = reply + length;
        result = -ESRCH;
        for (int bit = 0; bit < RTAX_MAX; bit++) {
            if ((header->rtm_addrs & (1 << bit)) == 0) {
                continue;
            }
            if (cursor + sizeof(struct sockaddr) > end) {
                break;
            }
            struct sockaddr *address_entry = (struct sockaddr *)cursor;
            size_t entry_length = address_entry->sa_len;
            if (entry_length == 0) {
                entry_length = sizeof(long);
            }
            if (cursor + entry_length > end) {
                break;
            }
            if (bit == RTAX_IFP && address_entry->sa_family == AF_LINK) {
                struct sockaddr_dl *link = (struct sockaddr_dl *)address_entry;
                if (link->sdl_nlen > 0 && link->sdl_nlen < out_length) {
                    memcpy(out_name, link->sdl_data, link->sdl_nlen);
                    out_name[link->sdl_nlen] = '\0';
                    result = 0;
                } else if (link->sdl_index != 0) {
                    // The kernel often returns the interface by index with no
                    // name attached; route(8) resolves it the same way.
                    result = if_indextoname(link->sdl_index, out_name) != NULL ? 0 : -ENODEV;
                }
                break;
            }
            cursor += (entry_length + sizeof(long) - 1) & ~(sizeof(long) - 1);
        }
        // Last resort: the header carries the index even when no usable IFP
        // sockaddr came back.
        if (result != 0 && header->rtm_index != 0) {
            result = if_indextoname(header->rtm_index, out_name) != NULL ? 0 : -ENODEV;
        }
        break;
    }

    pthread_mutex_unlock(&route_lock);
    return result;
}
