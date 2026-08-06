#ifndef C_MIHOMO_DNS_SYSTEM_H
#define C_MIHOMO_DNS_SYSTEM_H

#include <stddef.h>

int mihomo_dns_interface_has_ipv4(const char *interface_name, const char *address);
int mihomo_dns_add_ipv4_alias(const char *interface_name, const char *address, const char *netmask);
int mihomo_dns_remove_ipv4_alias(const char *interface_name, const char *address);
int mihomo_dns_pid_executable_matches(int pid, const char *path);
void mihomo_dns_install_crash_signal_handlers(const char *crash_log_path);

/// Names the interface the kernel would route `address` through.
///
/// Writes an interface name into `out_name` (which must hold at least
/// IF_NAMESIZE bytes) and returns 0, or returns a negative errno.
int mihomo_dns_route_interface(const char *address, char *out_name, size_t out_length);

#endif
