import Foundation

/// Mihomo-aware additions layered over the native YAML text editor.
///
/// This is intentionally independent from the view implementation so a later
/// pinned editor engine can reuse the same completion and highlighting model.
enum MihomoProfileLanguage {
  static let keys = [
    "allow-lan", "authentication", "bind-address", "cgroup-auto-redir",
    "cgroup-level", "client-fingerprint", "clash-for-android",
    "controller-cors", "dns", "external-controller", "external-ui",
    "external-ui-name", "external-ui-url", "find-process-mode", "geodata-loader",
    "geo-auto-update", "geo-update-interval", "geox-url", "global-client-fingerprint",
    "hosts", "inbound-tfo", "inbound-mptcp", "interface-name", "ipv6",
    "keep-alive-idle", "keep-alive-interval", "listeners", "log-level",
    "mixed-port", "mode", "ntp", "profile", "proxy-groups", "proxy-providers",
    "proxies", "redir-port", "routing-mark", "rules", "rule-providers",
    "secret", "skip-auth-prefixes", "sniffer", "socks-port", "store-fake-ip",
    "store-selected", "sub-rules", "tcp-concurrent", "tproxy-port", "tun",
    "unified-delay", "use-hosts", "websocket", "global-ua",
  ].sorted()

  private static let keySet = Set(keys)

  static func isKnownKey(_ value: String) -> Bool {
    keySet.contains(value)
  }

  static func completions(for partial: String) -> [String] {
    let normalized = partial.lowercased()
    guard !normalized.isEmpty else { return keys }
    return keys.filter { $0.hasPrefix(normalized) }
  }
}
