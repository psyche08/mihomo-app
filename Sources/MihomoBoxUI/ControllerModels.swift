import Foundation

extension KeyedDecodingContainer {
  fileprivate func decodeOrDefault<Value: Decodable>(
    _ type: Value.Type,
    forKey key: Key,
    default defaultValue: @autoclosure () -> Value
  ) throws -> Value {
    try decodeIfPresent(type, forKey: key) ?? defaultValue()
  }
}

/// A forward-compatible JSON value used only for controller metadata that has
/// no stable schema. Privileged commands never accept this type as input.
public enum ControllerJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case object([String: ControllerJSONValue])
  case array([ControllerJSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: ControllerJSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([ControllerJSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "unsupported controller JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct ControllerVersion: Codable, Equatable, Sendable {
  public var meta: Bool
  public var version: String

  public init(meta: Bool = false, version: String = "") {
    self.meta = meta
    self.version = version
  }

  enum CodingKeys: String, CodingKey { case meta, version }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    meta = try container.decodeOrDefault(Bool.self, forKey: .meta, default: false)
    version = try container.decodeOrDefault(String.self, forKey: .version, default: "")
  }
}

public struct ControllerTUNConfig: Codable, Equatable, Sendable {
  public var enable: Bool
  public var device: String
  public var stack: String
  public var dnsHijack: [String]
  public var autoRoute: Bool
  public var autoDetectInterface: Bool
  public var fileDescriptor: Int?

  public init(
    enable: Bool = false,
    device: String = "",
    stack: String = "",
    dnsHijack: [String] = [],
    autoRoute: Bool = false,
    autoDetectInterface: Bool = false,
    fileDescriptor: Int? = nil
  ) {
    self.enable = enable
    self.device = device
    self.stack = stack
    self.dnsHijack = dnsHijack
    self.autoRoute = autoRoute
    self.autoDetectInterface = autoDetectInterface
    self.fileDescriptor = fileDescriptor
  }

  enum CodingKeys: String, CodingKey {
    case enable, device, stack
    case dnsHijack = "dns-hijack"
    case autoRoute = "auto-route"
    case autoDetectInterface = "auto-detect-interface"
    case fileDescriptor = "file-descriptor"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enable = try container.decodeOrDefault(Bool.self, forKey: .enable, default: false)
    device = try container.decodeOrDefault(String.self, forKey: .device, default: "")
    stack = try container.decodeOrDefault(String.self, forKey: .stack, default: "")
    dnsHijack = try container.decodeOrDefault([String].self, forKey: .dnsHijack, default: [])
    autoRoute = try container.decodeOrDefault(Bool.self, forKey: .autoRoute, default: false)
    autoDetectInterface = try container.decodeOrDefault(
      Bool.self,
      forKey: .autoDetectInterface,
      default: false
    )
    fileDescriptor = try container.decodeIfPresent(Int.self, forKey: .fileDescriptor)
  }
}

public struct ControllerDNSConfig: Codable, Equatable, Sendable {
  public var enable: Bool
  public var enhancedMode: String
  public var nameserver: [String]
  public var directNameserver: [String]
  public var proxyServerNameserver: [String]
  public var fallback: [String]
  public var fakeIPRange: String
  public var useHosts: Bool
  public var respectRules: Bool?

  public init(
    enable: Bool = false,
    enhancedMode: String = "",
    nameserver: [String] = [],
    directNameserver: [String] = [],
    proxyServerNameserver: [String] = [],
    fallback: [String] = [],
    fakeIPRange: String = "",
    useHosts: Bool = false,
    respectRules: Bool? = nil
  ) {
    self.enable = enable
    self.enhancedMode = enhancedMode
    self.nameserver = nameserver
    self.directNameserver = directNameserver
    self.proxyServerNameserver = proxyServerNameserver
    self.fallback = fallback
    self.fakeIPRange = fakeIPRange
    self.useHosts = useHosts
    self.respectRules = respectRules
  }

  enum CodingKeys: String, CodingKey {
    case enable
    case enhancedMode = "enhanced-mode"
    case nameserver
    case directNameserver = "direct-nameserver"
    case proxyServerNameserver = "proxy-server-nameserver"
    case fallback
    case fakeIPRange = "fake-ip-range"
    case useHosts = "use-hosts"
    case respectRules = "respect-rules"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enable = try container.decodeOrDefault(Bool.self, forKey: .enable, default: false)
    enhancedMode = try container.decodeOrDefault(String.self, forKey: .enhancedMode, default: "")
    nameserver = try container.decodeOrDefault([String].self, forKey: .nameserver, default: [])
    directNameserver = try container.decodeOrDefault(
      [String].self,
      forKey: .directNameserver,
      default: []
    )
    proxyServerNameserver = try container.decodeOrDefault(
      [String].self,
      forKey: .proxyServerNameserver,
      default: []
    )
    fallback = try container.decodeOrDefault([String].self, forKey: .fallback, default: [])
    fakeIPRange = try container.decodeOrDefault(String.self, forKey: .fakeIPRange, default: "")
    useHosts = try container.decodeOrDefault(Bool.self, forKey: .useHosts, default: false)
    respectRules = try container.decodeIfPresent(Bool.self, forKey: .respectRules)
  }
}

public struct ControllerConfig: Codable, Equatable, Sendable {
  public var mode: String
  public var modeList: [String]
  public var port: Int?
  public var socksPort: Int?
  public var redirPort: Int?
  public var tproxyPort: Int?
  public var mixedPort: Int?
  public var tun: ControllerTUNConfig
  public var dns: ControllerDNSConfig?
  public var allowLAN: Bool
  public var bindAddress: String
  public var inboundTFO: Bool
  public var unifiedDelay: Bool?
  public var logLevel: String
  public var ipv6: Bool
  public var interfaceName: String
  public var geodataMode: Bool
  public var geodataLoader: String
  public var tcpConcurrent: Bool
  public var findProcessMode: String

  public init(
    mode: String = "",
    modeList: [String] = [],
    port: Int? = nil,
    socksPort: Int? = nil,
    redirPort: Int? = nil,
    tproxyPort: Int? = nil,
    mixedPort: Int? = nil,
    tun: ControllerTUNConfig = .init(),
    dns: ControllerDNSConfig? = nil,
    allowLAN: Bool = false,
    bindAddress: String = "",
    inboundTFO: Bool = false,
    unifiedDelay: Bool? = nil,
    logLevel: String = "",
    ipv6: Bool = false,
    interfaceName: String = "",
    geodataMode: Bool = false,
    geodataLoader: String = "",
    tcpConcurrent: Bool = false,
    findProcessMode: String = ""
  ) {
    self.mode = mode
    self.modeList = modeList
    self.port = port
    self.socksPort = socksPort
    self.redirPort = redirPort
    self.tproxyPort = tproxyPort
    self.mixedPort = mixedPort
    self.tun = tun
    self.dns = dns
    self.allowLAN = allowLAN
    self.bindAddress = bindAddress
    self.inboundTFO = inboundTFO
    self.unifiedDelay = unifiedDelay
    self.logLevel = logLevel
    self.ipv6 = ipv6
    self.interfaceName = interfaceName
    self.geodataMode = geodataMode
    self.geodataLoader = geodataLoader
    self.tcpConcurrent = tcpConcurrent
    self.findProcessMode = findProcessMode
  }

  enum CodingKeys: String, CodingKey {
    case mode
    case modeList = "mode-list"
    case port
    case socksPort = "socks-port"
    case redirPort = "redir-port"
    case tproxyPort = "tproxy-port"
    case mixedPort = "mixed-port"
    case tun, dns
    case allowLAN = "allow-lan"
    case bindAddress = "bind-address"
    case inboundTFO = "inbound-tfo"
    case unifiedDelay = "unified-delay"
    case legacyUnifiedDelay = "UnifiedDelay"
    case logLevel = "log-level"
    case ipv6
    case interfaceName = "interface-name"
    case geodataMode = "geodata-mode"
    case geodataLoader = "geodata-loader"
    case tcpConcurrent = "tcp-concurrent"
    case findProcessMode = "find-process-mode"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decodeOrDefault(String.self, forKey: .mode, default: "")
    modeList = try container.decodeOrDefault([String].self, forKey: .modeList, default: [])
    port = try container.decodeIfPresent(Int.self, forKey: .port)
    socksPort = try container.decodeIfPresent(Int.self, forKey: .socksPort)
    redirPort = try container.decodeIfPresent(Int.self, forKey: .redirPort)
    tproxyPort = try container.decodeIfPresent(Int.self, forKey: .tproxyPort)
    mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort)
    tun = try container.decodeOrDefault(ControllerTUNConfig.self, forKey: .tun, default: .init())
    dns = try container.decodeIfPresent(ControllerDNSConfig.self, forKey: .dns)
    allowLAN = try container.decodeOrDefault(Bool.self, forKey: .allowLAN, default: false)
    bindAddress = try container.decodeOrDefault(String.self, forKey: .bindAddress, default: "")
    inboundTFO = try container.decodeOrDefault(Bool.self, forKey: .inboundTFO, default: false)
    unifiedDelay =
      try container.decodeIfPresent(Bool.self, forKey: .unifiedDelay)
      ?? container.decodeIfPresent(Bool.self, forKey: .legacyUnifiedDelay)
    logLevel = try container.decodeOrDefault(String.self, forKey: .logLevel, default: "")
    ipv6 = try container.decodeOrDefault(Bool.self, forKey: .ipv6, default: false)
    interfaceName = try container.decodeOrDefault(String.self, forKey: .interfaceName, default: "")
    geodataMode = try container.decodeOrDefault(Bool.self, forKey: .geodataMode, default: false)
    geodataLoader = try container.decodeOrDefault(String.self, forKey: .geodataLoader, default: "")
    tcpConcurrent = try container.decodeOrDefault(Bool.self, forKey: .tcpConcurrent, default: false)
    findProcessMode = try container.decodeOrDefault(
      String.self,
      forKey: .findProcessMode,
      default: ""
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(modeList, forKey: .modeList)
    try container.encodeIfPresent(port, forKey: .port)
    try container.encodeIfPresent(socksPort, forKey: .socksPort)
    try container.encodeIfPresent(redirPort, forKey: .redirPort)
    try container.encodeIfPresent(tproxyPort, forKey: .tproxyPort)
    try container.encodeIfPresent(mixedPort, forKey: .mixedPort)
    try container.encode(tun, forKey: .tun)
    try container.encodeIfPresent(dns, forKey: .dns)
    try container.encode(allowLAN, forKey: .allowLAN)
    try container.encode(bindAddress, forKey: .bindAddress)
    try container.encode(inboundTFO, forKey: .inboundTFO)
    try container.encodeIfPresent(unifiedDelay, forKey: .unifiedDelay)
    try container.encode(logLevel, forKey: .logLevel)
    try container.encode(ipv6, forKey: .ipv6)
    try container.encode(interfaceName, forKey: .interfaceName)
    try container.encode(geodataMode, forKey: .geodataMode)
    try container.encode(geodataLoader, forKey: .geodataLoader)
    try container.encode(tcpConcurrent, forKey: .tcpConcurrent)
    try container.encode(findProcessMode, forKey: .findProcessMode)
  }
}

public struct ControllerDelayHistory: Codable, Equatable, Sendable {
  public var time: String
  public var delay: Int

  public init(time: String = "", delay: Int = 0) {
    self.time = time
    self.delay = delay
  }

  enum CodingKeys: String, CodingKey { case time, delay }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    time = try container.decodeOrDefault(String.self, forKey: .time, default: "")
    delay = try container.decodeOrDefault(Int.self, forKey: .delay, default: 0)
  }
}

public struct ControllerProxy: Codable, Equatable, Sendable {
  public var name: String
  public var type: String
  public var all: [String]
  public var icon: String?
  public var extra: [String: ControllerJSONValue]
  public var history: [ControllerDelayHistory]
  public var hidden: Bool
  public var alive: Bool?
  public var udp: Bool
  public var xudp: Bool
  public var tfo: Bool
  public var now: String
  public var fixed: String?
  public var testURL: String?
  public var timeout: Int?
  public var id: String?

  public init(
    name: String = "",
    type: String = "",
    all: [String] = [],
    icon: String? = nil,
    extra: [String: ControllerJSONValue] = [:],
    history: [ControllerDelayHistory] = [],
    hidden: Bool = false,
    alive: Bool? = nil,
    udp: Bool = false,
    xudp: Bool = false,
    tfo: Bool = false,
    now: String = "",
    fixed: String? = nil,
    testURL: String? = nil,
    timeout: Int? = nil,
    id: String? = nil
  ) {
    self.name = name
    self.type = type
    self.all = all
    self.icon = icon
    self.extra = extra
    self.history = history
    self.hidden = hidden
    self.alive = alive
    self.udp = udp
    self.xudp = xudp
    self.tfo = tfo
    self.now = now
    self.fixed = fixed
    self.testURL = testURL
    self.timeout = timeout
    self.id = id
  }

  enum CodingKeys: String, CodingKey {
    case name, type, all, icon, extra, history, hidden, alive, udp, xudp, tfo, now, fixed, timeout,
      id
    case testURL = "testUrl"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decodeOrDefault(String.self, forKey: .name, default: "")
    type = try container.decodeOrDefault(String.self, forKey: .type, default: "")
    all = try container.decodeOrDefault([String].self, forKey: .all, default: [])
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    extra = try container.decodeOrDefault(
      [String: ControllerJSONValue].self,
      forKey: .extra,
      default: [:]
    )
    history = try container.decodeOrDefault(
      [ControllerDelayHistory].self,
      forKey: .history,
      default: []
    )
    hidden = try container.decodeOrDefault(Bool.self, forKey: .hidden, default: false)
    alive = try container.decodeIfPresent(Bool.self, forKey: .alive)
    udp = try container.decodeOrDefault(Bool.self, forKey: .udp, default: false)
    xudp = try container.decodeOrDefault(Bool.self, forKey: .xudp, default: false)
    tfo = try container.decodeOrDefault(Bool.self, forKey: .tfo, default: false)
    now = try container.decodeOrDefault(String.self, forKey: .now, default: "")
    fixed = try container.decodeIfPresent(String.self, forKey: .fixed)
    testURL = try container.decodeIfPresent(String.self, forKey: .testURL)
    timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
    id = try container.decodeIfPresent(String.self, forKey: .id)
  }
}

public struct ControllerProxyCatalog: Codable, Equatable, Sendable {
  public var proxies: [String: ControllerProxy]

  public init(proxies: [String: ControllerProxy] = [:]) {
    self.proxies = proxies
  }

  enum CodingKeys: String, CodingKey { case proxies }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var decoded = try container.decodeOrDefault(
      [String: ControllerProxy].self,
      forKey: .proxies,
      default: [:]
    )
    for (key, value) in decoded where value.name.isEmpty {
      var named = value
      named.name = key
      decoded[key] = named
    }
    proxies = decoded
  }
}

public struct ControllerSubscriptionInfo: Codable, Equatable, Sendable {
  public var download: Int64?
  public var upload: Int64?
  public var total: Int64?
  public var expire: Int64?

  public init(
    download: Int64? = nil, upload: Int64? = nil, total: Int64? = nil, expire: Int64? = nil
  ) {
    self.download = download
    self.upload = upload
    self.total = total
    self.expire = expire
  }

  enum CodingKeys: String, CodingKey {
    case download = "Download"
    case upload = "Upload"
    case total = "Total"
    case expire = "Expire"
  }
}

public struct ControllerProxyProvider: Codable, Equatable, Sendable {
  public var subscriptionInfo: ControllerSubscriptionInfo?
  public var name: String
  public var proxies: [ControllerProxy]
  public var testURL: String
  public var timeout: Int?
  public var updatedAt: String
  public var vehicleType: String

  public init(
    subscriptionInfo: ControllerSubscriptionInfo? = nil,
    name: String = "",
    proxies: [ControllerProxy] = [],
    testURL: String = "",
    timeout: Int? = nil,
    updatedAt: String = "",
    vehicleType: String = ""
  ) {
    self.subscriptionInfo = subscriptionInfo
    self.name = name
    self.proxies = proxies
    self.testURL = testURL
    self.timeout = timeout
    self.updatedAt = updatedAt
    self.vehicleType = vehicleType
  }

  enum CodingKeys: String, CodingKey {
    case subscriptionInfo, name, proxies, timeout, updatedAt, vehicleType
    case testURL = "testUrl"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subscriptionInfo = try container.decodeIfPresent(
      ControllerSubscriptionInfo.self, forKey: .subscriptionInfo)
    name = try container.decodeOrDefault(String.self, forKey: .name, default: "")
    proxies = try container.decodeOrDefault([ControllerProxy].self, forKey: .proxies, default: [])
    testURL = try container.decodeOrDefault(String.self, forKey: .testURL, default: "")
    timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
    updatedAt = try container.decodeOrDefault(String.self, forKey: .updatedAt, default: "")
    vehicleType = try container.decodeOrDefault(String.self, forKey: .vehicleType, default: "")
  }
}

public struct ControllerProxyProviderCatalog: Codable, Equatable, Sendable {
  public var providers: [String: ControllerProxyProvider]

  public init(providers: [String: ControllerProxyProvider] = [:]) {
    self.providers = providers
  }

  enum CodingKeys: String, CodingKey { case providers }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var decoded = try container.decodeOrDefault(
      [String: ControllerProxyProvider].self,
      forKey: .providers,
      default: [:]
    )
    for (key, value) in decoded where value.name.isEmpty {
      var named = value
      named.name = key
      decoded[key] = named
    }
    providers = decoded
  }
}

public struct ControllerRuleExtra: Codable, Equatable, Sendable {
  public var disabled: Bool?
  public var hitCount: Int64?
  public var hitAt: String?
  public var missCount: Int64?
  public var missAt: String?

  public init(
    disabled: Bool? = nil,
    hitCount: Int64? = nil,
    hitAt: String? = nil,
    missCount: Int64? = nil,
    missAt: String? = nil
  ) {
    self.disabled = disabled
    self.hitCount = hitCount
    self.hitAt = hitAt
    self.missCount = missCount
    self.missAt = missAt
  }
}

public struct ControllerRule: Codable, Equatable, Sendable {
  public var index: Int
  public var type: String
  public var payload: String
  public var proxy: String
  public var size: Int
  public var extra: ControllerRuleExtra?

  public init(
    index: Int = 0,
    type: String = "",
    payload: String = "",
    proxy: String = "",
    size: Int = 0,
    extra: ControllerRuleExtra? = nil
  ) {
    self.index = index
    self.type = type
    self.payload = payload
    self.proxy = proxy
    self.size = size
    self.extra = extra
  }

  enum CodingKeys: String, CodingKey { case index, type, payload, proxy, size, extra }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    index = try container.decodeOrDefault(Int.self, forKey: .index, default: 0)
    type = try container.decodeOrDefault(String.self, forKey: .type, default: "")
    payload = try container.decodeOrDefault(String.self, forKey: .payload, default: "")
    proxy = try container.decodeOrDefault(String.self, forKey: .proxy, default: "")
    size = try container.decodeOrDefault(Int.self, forKey: .size, default: 0)
    extra = try container.decodeIfPresent(ControllerRuleExtra.self, forKey: .extra)
  }
}

public struct ControllerRuleCatalog: Codable, Equatable, Sendable {
  public var rules: [ControllerRule]

  public init(rules: [ControllerRule] = []) {
    self.rules = rules
  }

  enum CodingKeys: String, CodingKey { case rules }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.rules), try !container.decodeNil(forKey: .rules) else {
      rules = []
      return
    }
    if let indexed = try? container.decode([String: ControllerRule].self, forKey: .rules) {
      rules = indexed.map { key, value in
        var rule = value
        if let index = Int(key) { rule.index = index }
        return rule
      }.sorted { lhs, rhs in lhs.index < rhs.index }
    } else {
      rules = try container.decode([ControllerRule].self, forKey: .rules)
    }
  }
}

public struct ControllerRuleProvider: Codable, Equatable, Sendable {
  public var behavior: String
  public var format: String
  public var name: String
  public var ruleCount: Int
  public var type: String
  public var updatedAt: String
  public var vehicleType: String

  public init(
    behavior: String = "",
    format: String = "",
    name: String = "",
    ruleCount: Int = 0,
    type: String = "",
    updatedAt: String = "",
    vehicleType: String = ""
  ) {
    self.behavior = behavior
    self.format = format
    self.name = name
    self.ruleCount = ruleCount
    self.type = type
    self.updatedAt = updatedAt
    self.vehicleType = vehicleType
  }

  enum CodingKeys: String, CodingKey {
    case behavior, format, name, ruleCount, type, updatedAt, vehicleType
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    behavior = try container.decodeOrDefault(String.self, forKey: .behavior, default: "")
    format = try container.decodeOrDefault(String.self, forKey: .format, default: "")
    name = try container.decodeOrDefault(String.self, forKey: .name, default: "")
    ruleCount = try container.decodeOrDefault(Int.self, forKey: .ruleCount, default: 0)
    type = try container.decodeOrDefault(String.self, forKey: .type, default: "")
    updatedAt = try container.decodeOrDefault(String.self, forKey: .updatedAt, default: "")
    vehicleType = try container.decodeOrDefault(String.self, forKey: .vehicleType, default: "")
  }
}

public struct ControllerRuleProviderCatalog: Codable, Equatable, Sendable {
  public var providers: [String: ControllerRuleProvider]

  public init(providers: [String: ControllerRuleProvider] = [:]) {
    self.providers = providers
  }

  enum CodingKeys: String, CodingKey { case providers }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var decoded = try container.decodeOrDefault(
      [String: ControllerRuleProvider].self,
      forKey: .providers,
      default: [:]
    )
    for (key, value) in decoded where value.name.isEmpty {
      var named = value
      named.name = key
      decoded[key] = named
    }
    providers = decoded
  }
}

public struct ControllerConnectionMetadata: Codable, Equatable, Sendable {
  public var network: String
  public var type: String
  public var destinationIP: String
  public var destinationPort: String
  public var dnsMode: String
  public var host: String
  public var inboundIP: String
  public var inboundName: String
  public var inboundPort: String
  public var inboundUser: String
  public var process: String
  public var processPath: String
  public var remoteDestination: String
  public var sniffHost: String
  public var sourceIP: String
  public var sourcePort: String
  public var specialProxy: String
  public var specialRules: String
  public var uid: Int64?

  public init(
    network: String = "",
    type: String = "",
    destinationIP: String = "",
    destinationPort: String = "",
    dnsMode: String = "",
    host: String = "",
    inboundIP: String = "",
    inboundName: String = "",
    inboundPort: String = "",
    inboundUser: String = "",
    process: String = "",
    processPath: String = "",
    remoteDestination: String = "",
    sniffHost: String = "",
    sourceIP: String = "",
    sourcePort: String = "",
    specialProxy: String = "",
    specialRules: String = "",
    uid: Int64? = nil
  ) {
    self.network = network
    self.type = type
    self.destinationIP = destinationIP
    self.destinationPort = destinationPort
    self.dnsMode = dnsMode
    self.host = host
    self.inboundIP = inboundIP
    self.inboundName = inboundName
    self.inboundPort = inboundPort
    self.inboundUser = inboundUser
    self.process = process
    self.processPath = processPath
    self.remoteDestination = remoteDestination
    self.sniffHost = sniffHost
    self.sourceIP = sourceIP
    self.sourcePort = sourcePort
    self.specialProxy = specialProxy
    self.specialRules = specialRules
    self.uid = uid
  }

  enum CodingKeys: String, CodingKey {
    case network, type, destinationIP, destinationPort, dnsMode, host, inboundIP, inboundName
    case inboundPort, inboundUser, process, processPath, remoteDestination, sniffHost, sourceIP
    case sourcePort, specialProxy, specialRules, uid
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    network = try container.decodeOrDefault(String.self, forKey: .network, default: "")
    type = try container.decodeOrDefault(String.self, forKey: .type, default: "")
    destinationIP = try container.decodeOrDefault(String.self, forKey: .destinationIP, default: "")
    destinationPort = try container.decodeOrDefault(
      String.self, forKey: .destinationPort, default: "")
    dnsMode = try container.decodeOrDefault(String.self, forKey: .dnsMode, default: "")
    host = try container.decodeOrDefault(String.self, forKey: .host, default: "")
    inboundIP = try container.decodeOrDefault(String.self, forKey: .inboundIP, default: "")
    inboundName = try container.decodeOrDefault(String.self, forKey: .inboundName, default: "")
    inboundPort = try container.decodeOrDefault(String.self, forKey: .inboundPort, default: "")
    inboundUser = try container.decodeOrDefault(String.self, forKey: .inboundUser, default: "")
    process = try container.decodeOrDefault(String.self, forKey: .process, default: "")
    processPath = try container.decodeOrDefault(String.self, forKey: .processPath, default: "")
    remoteDestination = try container.decodeOrDefault(
      String.self,
      forKey: .remoteDestination,
      default: ""
    )
    sniffHost = try container.decodeOrDefault(String.self, forKey: .sniffHost, default: "")
    sourceIP = try container.decodeOrDefault(String.self, forKey: .sourceIP, default: "")
    sourcePort = try container.decodeOrDefault(String.self, forKey: .sourcePort, default: "")
    specialProxy = try container.decodeOrDefault(String.self, forKey: .specialProxy, default: "")
    specialRules = try container.decodeOrDefault(String.self, forKey: .specialRules, default: "")
    uid = try container.decodeIfPresent(Int64.self, forKey: .uid)
  }
}

public struct ControllerConnection: Codable, Equatable, Sendable {
  public var id: String
  public var download: Int64
  public var upload: Int64
  public var chains: [String]
  public var rule: String
  public var rulePayload: String
  public var start: String
  public var metadata: ControllerConnectionMetadata

  public init(
    id: String = "",
    download: Int64 = 0,
    upload: Int64 = 0,
    chains: [String] = [],
    rule: String = "",
    rulePayload: String = "",
    start: String = "",
    metadata: ControllerConnectionMetadata = .init()
  ) {
    self.id = id
    self.download = download
    self.upload = upload
    self.chains = chains
    self.rule = rule
    self.rulePayload = rulePayload
    self.start = start
    self.metadata = metadata
  }

  enum CodingKeys: String, CodingKey {
    case id, download, upload, chains, rule, rulePayload, start, metadata
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeOrDefault(String.self, forKey: .id, default: "")
    download = try container.decodeOrDefault(Int64.self, forKey: .download, default: 0)
    upload = try container.decodeOrDefault(Int64.self, forKey: .upload, default: 0)
    chains = try container.decodeOrDefault([String].self, forKey: .chains, default: [])
    rule = try container.decodeOrDefault(String.self, forKey: .rule, default: "")
    rulePayload = try container.decodeOrDefault(String.self, forKey: .rulePayload, default: "")
    start = try container.decodeOrDefault(String.self, forKey: .start, default: "")
    metadata = try container.decodeOrDefault(
      ControllerConnectionMetadata.self,
      forKey: .metadata,
      default: .init()
    )
  }
}

public struct ControllerConnectionsFrame: Codable, Equatable, Sendable {
  public var connections: [ControllerConnection]
  public var uploadTotal: Int64
  public var downloadTotal: Int64

  public init(
    connections: [ControllerConnection] = [],
    uploadTotal: Int64 = 0,
    downloadTotal: Int64 = 0
  ) {
    self.connections = connections
    self.uploadTotal = uploadTotal
    self.downloadTotal = downloadTotal
  }

  enum CodingKeys: String, CodingKey { case connections, uploadTotal, downloadTotal }

  public init(from decoder: Decoder) throws {
    let singleValue = try decoder.singleValueContainer()
    if singleValue.decodeNil() {
      self.init()
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let connections = try container.decodeOrDefault(
      [ControllerConnection].self,
      forKey: .connections,
      default: []
    )
    let uploadTotal = try container.decodeOrDefault(Int64.self, forKey: .uploadTotal, default: 0)
    let downloadTotal = try container.decodeOrDefault(
      Int64.self,
      forKey: .downloadTotal,
      default: 0
    )
    self.init(
      connections: connections,
      uploadTotal: uploadTotal,
      downloadTotal: downloadTotal
    )
  }
}

public struct ControllerTrafficFrame: Codable, Equatable, Sendable {
  public var up: Int64
  public var down: Int64

  public init(up: Int64 = 0, down: Int64 = 0) {
    self.up = up
    self.down = down
  }

  enum CodingKeys: String, CodingKey { case up, down }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    up = try container.decodeOrDefault(Int64.self, forKey: .up, default: 0)
    down = try container.decodeOrDefault(Int64.self, forKey: .down, default: 0)
  }
}

public struct ControllerMemoryFrame: Codable, Equatable, Sendable {
  public var inuse: Int64
  public var oslimit: Int64?

  public init(inuse: Int64 = 0, oslimit: Int64? = nil) {
    self.inuse = inuse
    self.oslimit = oslimit
  }

  enum CodingKeys: String, CodingKey { case inuse, oslimit }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inuse = try container.decodeOrDefault(Int64.self, forKey: .inuse, default: 0)
    oslimit = try container.decodeIfPresent(Int64.self, forKey: .oslimit)
  }
}

public struct ControllerLogFrame: Codable, Equatable, Sendable {
  public var type: String
  public var payload: String

  public init(type: String = "", payload: String = "") {
    self.type = type
    self.payload = payload
  }

  enum CodingKeys: String, CodingKey { case type, payload }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeOrDefault(String.self, forKey: .type, default: "")
    payload = try container.decodeOrDefault(String.self, forKey: .payload, default: "")
  }
}

public struct ControllerSnapshot: Codable, Equatable, Sendable {
  public var configs: ControllerConfig
  public var proxies: ControllerProxyCatalog

  public init(configs: ControllerConfig = .init(), proxies: ControllerProxyCatalog = .init()) {
    self.configs = configs
    self.proxies = proxies
  }

  enum CodingKeys: String, CodingKey { case configs, proxies }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    configs = try container.decodeOrDefault(
      ControllerConfig.self, forKey: .configs, default: .init())
    proxies = try container.decodeOrDefault(
      ControllerProxyCatalog.self,
      forKey: .proxies,
      default: .init()
    )
  }
}
