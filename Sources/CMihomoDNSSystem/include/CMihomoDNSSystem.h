#ifndef C_MIHOMO_DNS_SYSTEM_H
#define C_MIHOMO_DNS_SYSTEM_H

#include <stddef.h>
#include <stdint.h>

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

enum {
    MIHOMO_DNS_ROUTE_EVENT_ROUTE = 1u << 0,
    MIHOMO_DNS_ROUTE_EVENT_ADDRESS = 1u << 1,
    MIHOMO_DNS_ROUTE_EVENT_INTERFACE = 1u << 2,
};

/// Opens a non-blocking PF_ROUTE socket dedicated to kernel route broadcasts.
/// Returns the descriptor, or a negative errno value.
int mihomo_dns_route_monitor_open(void);

/// Drains pending route messages and ORs MIHOMO_DNS_ROUTE_EVENT_* into out_mask.
/// Returns 0 after reaching EAGAIN, or a negative errno value.
int mihomo_dns_route_monitor_drain(int descriptor, uint32_t *out_mask);

/// Classifies a Darwin RTM_* message type. Exposed for parser unit tests.
uint32_t mihomo_dns_route_event_mask_for_type(uint8_t message_type);

#endif
