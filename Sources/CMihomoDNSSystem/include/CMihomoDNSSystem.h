#ifndef C_MIHOMO_DNS_SYSTEM_H
#define C_MIHOMO_DNS_SYSTEM_H

int mihomo_dns_interface_has_ipv4(const char *interface_name, const char *address);
int mihomo_dns_add_ipv4_alias(const char *interface_name, const char *address, const char *netmask);
int mihomo_dns_remove_ipv4_alias(const char *interface_name, const char *address);
int mihomo_dns_pid_executable_matches(int pid, const char *path);

#endif
