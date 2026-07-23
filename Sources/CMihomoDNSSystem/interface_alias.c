#include "CMihomoDNSSystem.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <libproc.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static int crash_log_descriptor = -1;

int mihomo_dns_interface_has_ipv4(const char *interface_name, const char *address) {
    struct in_addr expected;
    if (interface_name == NULL || address == NULL || inet_pton(AF_INET, address, &expected) != 1) {
        return -EINVAL;
    }

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return -errno;
    }

    int found = 0;
    for (struct ifaddrs *entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if (strcmp(entry->ifa_name, interface_name) != 0) {
            continue;
        }
        const struct sockaddr_in *socket_address = (const struct sockaddr_in *)entry->ifa_addr;
        if (socket_address->sin_addr.s_addr == expected.s_addr) {
            found = 1;
            break;
        }
    }
    freeifaddrs(interfaces);
    return found;
}

static int copy_sockaddr(struct sockaddr *destination, const char *address) {
    struct sockaddr_in value;
    memset(&value, 0, sizeof(value));
    value.sin_len = sizeof(value);
    value.sin_family = AF_INET;
    if (inet_pton(AF_INET, address, &value.sin_addr) != 1) {
        return EINVAL;
    }
    memcpy(destination, &value, sizeof(value));
    return 0;
}

int mihomo_dns_add_ipv4_alias(const char *interface_name, const char *address, const char *netmask) {
    int present = mihomo_dns_interface_has_ipv4(interface_name, address);
    if (present == 1) {
        return 0;
    }
    if (present < 0) {
        return present;
    }

    struct ifaliasreq request;
    memset(&request, 0, sizeof(request));
    if (strlcpy(request.ifra_name, interface_name, sizeof(request.ifra_name)) >= sizeof(request.ifra_name)) {
        return -ENAMETOOLONG;
    }
    int status = copy_sockaddr(&request.ifra_addr, address);
    if (status != 0) {
        return -status;
    }
    status = copy_sockaddr(&request.ifra_mask, netmask);
    if (status != 0) {
        return -status;
    }

    int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        return -errno;
    }
    status = ioctl(descriptor, SIOCAIFADDR, &request);
    int saved_errno = errno;
    close(descriptor);
    if (status == 0 || saved_errno == EEXIST) {
        return 0;
    }
    return -saved_errno;
}

int mihomo_dns_remove_ipv4_alias(const char *interface_name, const char *address) {
    int present = mihomo_dns_interface_has_ipv4(interface_name, address);
    if (present == 0) {
        return 0;
    }
    if (present < 0) {
        return present;
    }

    struct ifreq request;
    memset(&request, 0, sizeof(request));
    if (strlcpy(request.ifr_name, interface_name, sizeof(request.ifr_name)) >= sizeof(request.ifr_name)) {
        return -ENAMETOOLONG;
    }
    int status = copy_sockaddr(&request.ifr_addr, address);
    if (status != 0) {
        return -status;
    }

    int descriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (descriptor < 0) {
        return -errno;
    }
    status = ioctl(descriptor, SIOCDIFADDR, &request);
    int saved_errno = errno;
    close(descriptor);
    if (status == 0 || saved_errno == EADDRNOTAVAIL) {
        return 0;
    }
    return -saved_errno;
}

int mihomo_dns_pid_executable_matches(int pid, const char *path) {
    if (pid <= 0 || path == NULL) {
        return 0;
    }
    char actual[PROC_PIDPATHINFO_MAXSIZE];
    memset(actual, 0, sizeof(actual));
    int length = proc_pidpath(pid, actual, sizeof(actual));
    if (length <= 0) {
        return 0;
    }
    return strcmp(actual, path) == 0 ? 1 : 0;
}

static void crash_signal_handler(int signal_number) {
    int saved_errno = errno;
    const char *message = "level=error event=daemon_crashed signal=unknown\n";
    size_t length = strlen(message);
    switch (signal_number) {
        case SIGABRT:
            message = "level=error event=daemon_crashed signal=SIGABRT\n";
            length = sizeof("level=error event=daemon_crashed signal=SIGABRT\n") - 1;
            break;
        case SIGBUS:
            message = "level=error event=daemon_crashed signal=SIGBUS\n";
            length = sizeof("level=error event=daemon_crashed signal=SIGBUS\n") - 1;
            break;
        case SIGFPE:
            message = "level=error event=daemon_crashed signal=SIGFPE\n";
            length = sizeof("level=error event=daemon_crashed signal=SIGFPE\n") - 1;
            break;
        case SIGILL:
            message = "level=error event=daemon_crashed signal=SIGILL\n";
            length = sizeof("level=error event=daemon_crashed signal=SIGILL\n") - 1;
            break;
        case SIGSEGV:
            message = "level=error event=daemon_crashed signal=SIGSEGV\n";
            length = sizeof("level=error event=daemon_crashed signal=SIGSEGV\n") - 1;
            break;
    }
    if (crash_log_descriptor >= 0) {
        (void)write(crash_log_descriptor, message, length);
        (void)fsync(crash_log_descriptor);
    } else {
        (void)write(STDERR_FILENO, message, length);
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    (void)sigaction(signal_number, &action, NULL);
    errno = saved_errno;
    (void)kill(getpid(), signal_number);
    _exit(128 + signal_number);
}

void mihomo_dns_install_crash_signal_handlers(const char *crash_log_path) {
    if (crash_log_descriptor >= 0) {
        (void)close(crash_log_descriptor);
        crash_log_descriptor = -1;
    }
    if (crash_log_path != NULL) {
        crash_log_descriptor = open(
            crash_log_path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        );
    }
    const int signals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV};
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = crash_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND;
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        (void)sigaction(signals[index], &action, NULL);
    }
}
