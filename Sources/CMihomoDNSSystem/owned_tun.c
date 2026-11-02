#include "CMihomoDNSSystem.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define OWNED_UTUN_OPT_IFNAME 2

int mihomo_owned_tun_name(int fd, char *name, size_t capacity) {
    if (!name || capacity < IFNAMSIZ) return -EINVAL;
    struct sockaddr_ctl peer = {0};
    socklen_t length = sizeof(peer);
    if (getpeername(fd, (struct sockaddr *)&peer, &length) < 0) return -errno;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &info) < 0) return -errno;
    if (peer.sc_family != AF_SYSTEM || peer.sc_id != info.ctl_id) return -EINVAL;
    length = (socklen_t)capacity;
    if (getsockopt(fd, SYSPROTO_CONTROL, OWNED_UTUN_OPT_IFNAME, name, &length) < 0) return -errno;
    if (length == 0 || length > capacity || !memchr(name, 0, length) || strncmp(name, "utun", 4)) return -EINVAL;
    return 0;
}

int mihomo_owned_tun_create(void) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -errno;
    struct ctl_info info = {0};
    strlcpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name));
    int failure = 0;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || ioctl(fd, CTLIOCGINFO, &info) < 0) failure = errno;
    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address); address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL; address.sc_id = info.ctl_id;
    // Unit zero asks the kernel to allocate a fresh interface, never attach an
    // existing VPN's interface by a guessed utun number.
    if (!failure && connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) failure = errno;
    if (failure) { close(fd); return -failure; }
    return fd;
}

static int tun_ifreq(int fd, struct ifreq *request) {
    memset(request, 0, sizeof(*request));
    return mihomo_owned_tun_name(fd, request->ifr_name, sizeof(request->ifr_name));
}

int mihomo_owned_tun_set_up(int fd, int up, int mtu) {
    struct ifreq request;
    int result = tun_ifreq(fd, &request);
    if (result) return result;
    if (mtu < 1280 || mtu > 65535) return -EINVAL;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return -errno;
    request.ifr_mtu = mtu;
    if (ioctl(s, SIOCSIFMTU, &request) < 0) result = -errno;
    if (!result && ioctl(s, SIOCGIFFLAGS, &request) < 0) result = -errno;
    if (!result) {
        request.ifr_flags = up ? (request.ifr_flags | IFF_UP) : (request.ifr_flags & ~IFF_UP);
        if (ioctl(s, SIOCSIFFLAGS, &request) < 0) result = -errno;
    }
    close(s); return result;
}

int mihomo_owned_tun_address(int fd, const char *address, int bits, int add) {
    char name[IFNAMSIZ];
    int result = mihomo_owned_tun_name(fd, name, sizeof(name));
    if (result) return result;
    struct in_addr v4;
    struct in6_addr v6;
    int family = inet_pton(AF_INET, address, &v4) == 1 ? AF_INET : AF_INET6;
    if ((family == AF_INET && (bits < 0 || bits > 32)) ||
        (family == AF_INET6 && (bits < 0 || bits > 128 || inet_pton(AF_INET6, address, &v6) != 1))) return -EINVAL;
    int s = socket(family, SOCK_DGRAM, 0);
    if (s < 0) return -errno;
    if (family == AF_INET) {
        struct ifaliasreq request = {0};
        strlcpy(request.ifra_name, name, sizeof(request.ifra_name));
        struct sockaddr_in a = {0}, mask = {0};
        a.sin_len = sizeof(a); a.sin_family = AF_INET; a.sin_addr = v4;
        mask.sin_len = sizeof(mask); mask.sin_family = AF_INET;
        mask.sin_addr.s_addr = htonl(bits == 0 ? 0 : UINT32_MAX << (32-bits));
        memcpy(&request.ifra_addr, &a, sizeof(a));
        memcpy(&request.ifra_broadaddr, &a, sizeof(a));
        memcpy(&request.ifra_mask, &mask, sizeof(mask));
        if (ioctl(s, add ? SIOCAIFADDR : SIOCDIFADDR, &request) < 0) result = -errno;
    } else if (add) {
        struct in6_aliasreq request = {0};
        strlcpy(request.ifra_name, name, sizeof(request.ifra_name));
        request.ifra_addr.sin6_len = sizeof(struct sockaddr_in6);
        request.ifra_addr.sin6_family = AF_INET6; request.ifra_addr.sin6_addr = v6;
        request.ifra_prefixmask.sin6_len = sizeof(struct sockaddr_in6);
        request.ifra_prefixmask.sin6_family = AF_INET6;
        for (int i=0;i<16;i++) request.ifra_prefixmask.sin6_addr.s6_addr[i] = bits >= (i+1)*8 ? 255 : (bits > i*8 ? (255 << (8-(bits-i*8))) : 0);
        request.ifra_flags = IN6_IFF_NODAD;
        request.ifra_lifetime.ia6t_vltime = UINT32_MAX;
        request.ifra_lifetime.ia6t_pltime = UINT32_MAX;
        if (ioctl(s, SIOCAIFADDR_IN6, &request) < 0) result = -errno;
    } else {
        struct in6_ifreq request = {0};
        strlcpy(request.ifr_name, name, sizeof(request.ifr_name));
        request.ifr_addr.sin6_len = sizeof(struct sockaddr_in6);
        request.ifr_addr.sin6_family = AF_INET6; request.ifr_addr.sin6_addr = v6;
        if (ioctl(s, SIOCDIFADDR_IN6, &request) < 0) result = -errno;
    }
    close(s);
    if (!add && (result == -EADDRNOTAVAIL || result == -ENOENT)) return 0;
    return result;
}

// Each request uses a private socket, bounded ACK wait, and matching pid/seq.
// No fire-and-forget route writes and no replacement of a foreign route.
static int route_request(struct rt_msghdr *message) {
    static _Atomic unsigned int sequence = 0;
    int fd = socket(PF_ROUTE, SOCK_RAW, 0);
    if (fd < 0) return -errno;
    message->rtm_version = RTM_VERSION; message->rtm_seq = (int)atomic_fetch_add(&sequence, 1); message->rtm_pid = getpid();
    message->rtm_errno = 0;
    if (write(fd, message, message->rtm_msglen) != message->rtm_msglen) { int e = errno; close(fd); return -e; }
    char buffer[8192];
    struct pollfd wait = { .fd = fd, .events = POLLIN };
    struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
    int result = -ETIMEDOUT;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed = (now.tv_sec-start.tv_sec)*1000 + (now.tv_nsec-start.tv_nsec)/1000000;
        if (elapsed >= 1000 || poll(&wait, 1, (int)(1000-elapsed)) <= 0) break;
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < (ssize_t)sizeof(struct rt_msghdr)) continue;
        struct rt_msghdr *reply = (struct rt_msghdr *)buffer;
        if (reply->rtm_pid == getpid() && reply->rtm_seq == message->rtm_seq && reply->rtm_type == message->rtm_type) { result = -reply->rtm_errno; break; }
    }
    close(fd); return result;
}

int mihomo_owned_tun_route(int fd, const char *destination, int bits, const char *gateway, int add) {
    char name[IFNAMSIZ];
    int result = mihomo_owned_tun_name(fd, name, sizeof(name));
    if (result) return result;
    struct { struct rt_msghdr header; unsigned char data[256]; } message = {0};
    message.header.rtm_type = add ? RTM_ADD : RTM_DELETE;
    message.header.rtm_flags = RTF_UP | RTF_STATIC | RTF_GATEWAY;
    message.header.rtm_index = if_nametoindex(name);
    message.header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    struct sockaddr_in a4[3] = {0};
    struct sockaddr_in6 a6[3] = {0};
    if (inet_pton(AF_INET, destination, &a4[0].sin_addr) == 1) {
        if (bits < 0 || bits > 32 || inet_pton(AF_INET, gateway, &a4[1].sin_addr) != 1) return -EINVAL;
        for (int i=0;i<3;i++) { a4[i].sin_len=sizeof(a4[i]); a4[i].sin_family=AF_INET; }
        a4[2].sin_addr.s_addr = htonl(bits == 0 ? 0 : UINT32_MAX << (32-bits));
        memcpy(message.data, a4, sizeof(a4)); message.header.rtm_msglen = sizeof(message.header)+sizeof(a4);
    } else {
        if (bits < 0 || bits > 128 || inet_pton(AF_INET6, destination, &a6[0].sin6_addr) != 1 || inet_pton(AF_INET6, gateway, &a6[1].sin6_addr) != 1) return -EINVAL;
        for (int i=0;i<3;i++) { a6[i].sin6_len=sizeof(a6[i]); a6[i].sin6_family=AF_INET6; }
        for (int i=0;i<16;i++) a6[2].sin6_addr.s6_addr[i] = bits >= (i+1)*8 ? 255 : (bits > i*8 ? (255 << (8-(bits-i*8))) : 0);
        memcpy(message.data,a6,sizeof(a6)); message.header.rtm_msglen=sizeof(message.header)+sizeof(a6);
    }
    result=route_request(&message.header);
    return !add && result == -ESRCH ? 0 : result;
}

// The descriptor, not a caller-supplied interface name, authorizes cleanup.
// Delete addresses first; the kernel removes their connected/local routes.
int mihomo_owned_tun_clear(int fd) {
    char name[IFNAMSIZ];
    int result = mihomo_owned_tun_name(fd, name, sizeof(name));
    if (result) return result;
    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses) < 0) return -errno;
    for (struct ifaddrs *p=addresses;p;p=p->ifa_next) {
        if (!p->ifa_addr || strcmp(p->ifa_name,name)) continue;
        char address[INET6_ADDRSTRLEN]; const void *bytes = NULL;
        if (p->ifa_addr->sa_family == AF_INET) bytes=&((struct sockaddr_in *)p->ifa_addr)->sin_addr;
        if (p->ifa_addr->sa_family == AF_INET6) bytes=&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
        if (bytes && inet_ntop(p->ifa_addr->sa_family,bytes,address,sizeof(address))) {
            int e=mihomo_owned_tun_address(fd,address,0,0); if (e && !result) result=e;
        }
    }
    freeifaddrs(addresses);
    int routes = mihomo_owned_tun_clear_routes(fd);
    if (routes && !result) result = routes;
    int e=mihomo_owned_tun_set_up(fd,0,9000); if (e && !result) result=e;
    return result;
}

int mihomo_owned_tun_clear_routes(int fd) {
    char name[IFNAMSIZ];
    int result = mihomo_owned_tun_name(fd, name, sizeof(name));
    if (result) return result;
    unsigned int index = if_nametoindex(name);
    // Only gateway routes added to this dedicated interface need explicit
    // removal; never touch a competing route with a different interface index.
    int mib[]={CTL_NET,PF_ROUTE,0,AF_UNSPEC,NET_RT_DUMP,0}; size_t size=0;
    if (sysctl(mib,6,NULL,&size,NULL,0)<0) return -errno;
    char *buffer=malloc(size); if (!buffer) return -ENOMEM;
    if (sysctl(mib,6,buffer,&size,NULL,0)<0) { int e=errno;free(buffer);return -e; }
    for (char *p=buffer;p<buffer+size;) {
        struct rt_msghdr *r=(struct rt_msghdr *)p;
        if ((size_t)(buffer+size-p)<sizeof(*r) || r->rtm_msglen<sizeof(*r) || r->rtm_msglen>(size_t)(buffer+size-p)) { result=-EINVAL;break; }
        if (r->rtm_index == index && (r->rtm_flags & RTF_GATEWAY)) {
            r->rtm_type=RTM_DELETE;
            int e=route_request(r); if (e && e != -ESRCH && !result) result=e;
        }
        p+=r->rtm_msglen;
    }
    free(buffer);
    return result;
}
