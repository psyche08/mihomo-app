import Foundation

/// The minimum controller catalog needed to prove that Global mode resolves
/// through a real proxy rather than a built-in direct/reject route.
///
/// This value lives in the authenticated control module so the root daemon can
/// enforce the invariant inside one XPC mutation. UI-side checks remain useful
/// feedback, but they are not the privilege-boundary authority.
public struct ControllerRouteSnapshot: Equatable, Sendable {
  public struct Proxy: Equatable, Sendable {
    public var name: String
    public var type: String
    public var now: String
    public var all: [String]

    public init(name: String, type: String = "", now: String = "", all: [String] = []) {
      self.name = name
      self.type = type
      self.now = now
      self.all = all
    }
  }

  public var mode: String
  public var proxies: [String: Proxy]

  public init(mode: String, proxies: [String: Proxy]) {
    self.mode = mode.lowercased()
    self.proxies = proxies
  }

  public init(configsData: Data, proxiesData: Data) throws {
    guard
      let configs = try JSONSerialization.jsonObject(with: configsData) as? [String: Any],
      let mode = configs["mode"] as? String,
      let envelope = try JSONSerialization.jsonObject(with: proxiesData) as? [String: Any],
      let catalog = envelope["proxies"] as? [String: Any]
    else {
      throw ControllerRouteSnapshotError.invalidControllerSnapshot
    }

    var decoded: [String: Proxy] = [:]
    for (key, rawValue) in catalog {
      guard let value = rawValue as? [String: Any] else {
        throw ControllerRouteSnapshotError.invalidControllerSnapshot
      }
      let name = (value["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
      let type = value["type"] as? String ?? ""
      let now = value["now"] as? String ?? ""
      let all = value["all"] as? [String] ?? []
      decoded[key] = Proxy(name: name, type: type, now: now, all: all)
    }
    self.init(mode: mode, proxies: decoded)
  }

  public var globalSelection: String? {
    globalGroup?.now.isEmpty == false ? globalGroup?.now : nil
  }

  public var globalGroupName: String? {
    globalGroupEntry?.key
  }

  public var globalRoutesThroughProxy: Bool {
    guard let target = globalSelection else { return false }
    return targetRoutesThroughProxy(target, visited: [])
  }

  /// A safe existing or fallback target for the built-in GLOBAL selector.
  public var globalProxyTarget: String? {
    guard let globalGroup else { return nil }
    if !globalGroup.now.isEmpty,
      targetRoutesThroughProxy(globalGroup.now, visited: [])
    {
      return globalGroup.now
    }

    if let nested = globalGroup.all.first(where: { candidate in
      guard candidate.caseInsensitiveCompare("GLOBAL") != .orderedSame,
        let proxy = proxies[candidate], !proxy.all.isEmpty
      else {
        return false
      }
      return targetRoutesThroughProxy(candidate, visited: [])
    }) {
      return nested
    }
    return globalGroup.all.first {
      targetRoutesThroughProxy($0, visited: [])
    }
  }

  public func selection(for group: String) -> String? {
    proxies[group]?.now
  }

  public func selecting(group: String, proxy target: String) -> Self? {
    guard var selectedGroup = proxies[group], selectedGroup.all.contains(target) else {
      return nil
    }
    selectedGroup.now = target
    var copy = self
    copy.proxies[group] = selectedGroup
    return copy
  }

  private var globalGroup: Proxy? {
    globalGroupEntry?.value
  }

  private var globalGroupEntry: (key: String, value: Proxy)? {
    proxies["GLOBAL"].map { ("GLOBAL", $0) }
  }

  private func targetRoutesThroughProxy(_ target: String, visited: Set<String>) -> Bool {
    let builtins = Set([
      "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL",
    ])
    guard !builtins.contains(target.uppercased()), let proxy = proxies[target] else {
      return false
    }
    guard !proxy.all.isEmpty else {
      return Self.isRemoteProxyType(proxy.type)
    }
    guard !visited.contains(proxy.name), !proxy.now.isEmpty else { return false }
    var nextVisited = visited
    nextVisited.insert(proxy.name)
    return targetRoutesThroughProxy(proxy.now, visited: nextVisited)
  }

  /// Fail closed for controller pseudo-proxies and for unknown/missing types.
  /// The allowlist names concrete remote protocols supported by the pinned
  /// Mihomo release; adding a new protocol requires an explicit review.
  private static func isRemoteProxyType(_ type: String) -> Bool {
    switch type.lowercased() {
    case "ss", "ssr", "shadowsocks", "shadowsocksr", "socks", "socks5",
      "http", "vmess", "vless", "trojan", "snell", "hysteria",
      "hysteria2", "tuic", "wireguard", "ssh", "mieru", "anytls",
      "tor", "masque":
      return true
    default:
      return false
    }
  }
}

public enum ControllerRouteSnapshotError: Error, LocalizedError, Sendable {
  case invalidControllerSnapshot

  public var errorDescription: String? {
    "the controller route snapshot is invalid"
  }
}
