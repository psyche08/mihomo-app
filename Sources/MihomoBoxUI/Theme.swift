import Foundation
import SwiftUI

// MARK: - Navigation and loading state

public enum DashboardPage: String, CaseIterable, Identifiable, Sendable {
  case overview
  case proxies
  case rules
  case connections
  case usage
  case logs
  case config

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .proxies: "Proxies"
    case .rules: "Rules"
    case .connections: "Connections"
    case .usage: "Data Usage"
    case .logs: "Logs"
    case .config: "Config"
    }
  }

  public var symbol: String {
    switch self {
    case .overview: "house"
    case .proxies: "globe"
    case .rules: "ruler"
    case .connections: "network"
    case .usage: "chart.xyaxis.line"
    case .logs: "doc.on.doc"
    case .config: "gearshape"
    }
  }

  public var shortcut: KeyEquivalent {
    switch self {
    case .overview: "1"
    case .proxies: "2"
    case .rules: "3"
    case .connections: "4"
    case .usage: "5"
    case .logs: "6"
    case .config: "7"
    }
  }

  public var shortcutLabel: String {
    switch self {
    case .overview: "1"
    case .proxies: "2"
    case .rules: "3"
    case .connections: "4"
    case .usage: "5"
    case .logs: "6"
    case .config: "7"
    }
  }
}

public enum DashboardLoadState: Equatable, Sendable {
  case loading
  case loaded
  case empty(message: String)
  case failed(message: String)
}

public enum DashboardRuntimeStatus: String, Sendable {
  case connected
  case degraded
  case disconnected

  public var title: String {
    switch self {
    case .connected: "Connected"
    case .degraded: "Degraded"
    case .disconnected: "Disconnected"
    }
  }

  public var symbol: String {
    switch self {
    case .connected: "checkmark.circle.fill"
    case .degraded: "exclamationmark.triangle.fill"
    case .disconnected: "xmark.circle.fill"
    }
  }
}

// MARK: - Dashboard value types

public struct TrafficSnapshot: Equatable, Sendable {
  public var uploadSpeed: Int64
  public var downloadSpeed: Int64
  public var uploadTotal: Int64
  public var downloadTotal: Int64
  public var activeConnections: Int
  public var memoryBytes: Int64

  public init(
    uploadSpeed: Int64 = 0,
    downloadSpeed: Int64 = 0,
    uploadTotal: Int64 = 0,
    downloadTotal: Int64 = 0,
    activeConnections: Int = 0,
    memoryBytes: Int64 = 0
  ) {
    self.uploadSpeed = uploadSpeed
    self.downloadSpeed = downloadSpeed
    self.uploadTotal = uploadTotal
    self.downloadTotal = downloadTotal
    self.activeConnections = activeConnections
    self.memoryBytes = memoryBytes
  }
}

public struct TrafficPoint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var time: Date
  public var upload: Double
  public var download: Double

  public init(id: UUID = UUID(), time: Date, upload: Double, download: Double) {
    self.id = id
    self.time = time
    self.upload = upload
    self.download = download
  }
}

public struct MetricPoint: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var time: Date
  public var value: Double

  public init(id: UUID = UUID(), time: Date, value: Double) {
    self.id = id
    self.time = time
    self.value = value
  }
}

public struct ProxyNode: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var type: String
  public var latencyMilliseconds: Int?
  public var isSelected: Bool
  /// Controller reachability is distinct from whether a delay sample exists.
  /// `nil` means the controller did not report a health state.
  public var isAlive: Bool?
  public var supportsUDP: Bool

  public init(
    name: String,
    type: String,
    latencyMilliseconds: Int? = nil,
    isSelected: Bool = false,
    isAlive: Bool? = nil,
    supportsUDP: Bool = false
  ) {
    self.name = name
    self.type = type
    self.latencyMilliseconds = latencyMilliseconds
    self.isSelected = isSelected
    self.isAlive = isAlive
    self.supportsUDP = supportsUDP
  }
}

public struct ProxyGroup: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var type: String
  public var selectedNode: String?
  public var nodes: [ProxyNode]

  public init(name: String, type: String, selectedNode: String? = nil, nodes: [ProxyNode] = []) {
    self.name = name
    self.type = type
    self.selectedNode = selectedNode
    self.nodes = nodes
  }
}

public struct ProxyProvider: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var vehicleType: String
  public var updatedAt: Date?
  public var nodeCount: Int
  public var usedBytes: Int64?
  public var totalBytes: Int64?
  public var expiresAt: Date?
  public var nodes: [ProxyNode]

  public init(
    name: String,
    vehicleType: String,
    updatedAt: Date? = nil,
    nodeCount: Int,
    usedBytes: Int64? = nil,
    totalBytes: Int64? = nil,
    expiresAt: Date? = nil,
    nodes: [ProxyNode] = []
  ) {
    self.name = name
    self.vehicleType = vehicleType
    self.updatedAt = updatedAt
    self.nodeCount = nodeCount
    self.usedBytes = usedBytes
    self.totalBytes = totalBytes
    self.expiresAt = expiresAt
    self.nodes = nodes
  }
}

public struct DashboardRule: Identifiable, Equatable, Sendable {
  public var id: String
  public var index: Int
  public var type: String
  public var payload: String
  public var target: String
  public var isEnabled: Bool
  public var hitCount: Int
  public var missCount: Int
  public var size: Int
  public var lastMatchedAt: Date?
  public var lastUnmatchedAt: Date?

  public init(
    id: String,
    index: Int,
    type: String,
    payload: String,
    target: String,
    isEnabled: Bool = true,
    hitCount: Int = 0,
    missCount: Int = 0,
    size: Int = 0,
    lastMatchedAt: Date? = nil,
    lastUnmatchedAt: Date? = nil
  ) {
    self.id = id
    self.index = index
    self.type = type
    self.payload = payload
    self.target = target
    self.isEnabled = isEnabled
    self.hitCount = hitCount
    self.missCount = missCount
    self.size = size
    self.lastMatchedAt = lastMatchedAt
    self.lastUnmatchedAt = lastUnmatchedAt
  }
}

public struct RuleProvider: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var behavior: String
  public var format: String
  public var type: String
  public var vehicleType: String
  public var ruleCount: Int
  public var updatedAt: Date?

  public init(
    name: String,
    behavior: String,
    format: String = "",
    type: String = "",
    vehicleType: String = "",
    ruleCount: Int,
    updatedAt: Date? = nil
  ) {
    self.name = name
    self.behavior = behavior
    self.format = format
    self.type = type
    self.vehicleType = vehicleType
    self.ruleCount = ruleCount
    self.updatedAt = updatedAt
  }
}

public struct DashboardConnection: Identifiable, Equatable, Sendable {
  public var id: String
  public var host: String
  public var destination: String
  public var network: String
  public var connectionType: String
  public var source: String
  public var sourcePort: String
  public var destinationIP: String
  public var destinationPort: String
  public var user: String
  public var process: String?
  public var processPath: String?
  public var sniffHost: String?
  public var inboundName: String?
  public var dnsMode: String
  public var inboundIP: String
  public var inboundPort: String
  public var uid: Int64?
  public var rule: String
  public var rulePayload: String
  public var specialProxy: String
  public var specialRules: String
  public var chains: [String]
  public var uploadBytes: Int64
  public var downloadBytes: Int64
  public var uploadSpeed: Int64
  public var downloadSpeed: Int64
  public var startedAt: Date

  public init(
    id: String,
    host: String,
    destination: String,
    network: String,
    connectionType: String = "",
    source: String = "",
    sourcePort: String = "",
    destinationIP: String = "",
    destinationPort: String = "",
    user: String = "",
    process: String? = nil,
    processPath: String? = nil,
    sniffHost: String? = nil,
    inboundName: String? = nil,
    dnsMode: String = "",
    inboundIP: String = "",
    inboundPort: String = "",
    uid: Int64? = nil,
    rule: String,
    rulePayload: String = "",
    specialProxy: String = "",
    specialRules: String = "",
    chains: [String] = [],
    uploadBytes: Int64 = 0,
    downloadBytes: Int64 = 0,
    uploadSpeed: Int64 = 0,
    downloadSpeed: Int64 = 0,
    startedAt: Date
  ) {
    self.id = id
    self.host = host
    self.destination = destination
    self.network = network
    self.connectionType = connectionType
    self.source = source
    self.sourcePort = sourcePort
    self.destinationIP = destinationIP
    self.destinationPort = destinationPort
    self.user = user
    self.process = process
    self.processPath = processPath
    self.sniffHost = sniffHost
    self.inboundName = inboundName
    self.dnsMode = dnsMode
    self.inboundIP = inboundIP
    self.inboundPort = inboundPort
    self.uid = uid
    self.rule = rule
    self.rulePayload = rulePayload
    self.specialProxy = specialProxy
    self.specialRules = specialRules
    self.chains = chains
    self.uploadBytes = uploadBytes
    self.downloadBytes = downloadBytes
    self.uploadSpeed = uploadSpeed
    self.downloadSpeed = downloadSpeed
    self.startedAt = startedAt
  }
}

public enum UsageDimension: String, CaseIterable, Identifiable, Sendable {
  case device = "Devices"
  case user = "User"
  case host = "Host"
  case proxy = "Proxies"
  case process = "Process"

  public var id: String { rawValue }
}

public enum UsageRange: String, CaseIterable, Identifiable, Sendable {
  case hour = "1H"
  case day = "24H"
  case week = "7D"
  case month = "30D"

  public var id: String { rawValue }
}

public struct UsageRow: Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var uploadBytes: Int64
  public var downloadBytes: Int64
  public var connectionCount: Int

  public init(name: String, uploadBytes: Int64, downloadBytes: Int64, connectionCount: Int) {
    self.name = name
    self.uploadBytes = uploadBytes
    self.downloadBytes = downloadBytes
    self.connectionCount = connectionCount
  }
}

public enum DashboardLogLevel: String, CaseIterable, Identifiable, Sendable {
  case all = "All"
  case debug = "Debug"
  case info = "Info"
  case warning = "Warning"
  case error = "Error"

  public var id: String { rawValue }
}

public struct DashboardLogEntry: Identifiable, Equatable, Sendable {
  public var id: UInt64
  public var timestamp: Date
  public var level: DashboardLogLevel
  public var message: String

  public init(id: UInt64, timestamp: Date, level: DashboardLogLevel, message: String) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.message = message
  }
}

public enum DashboardProxyMode: String, CaseIterable, Identifiable, Sendable {
  case rule = "Rule"
  case global = "Global"
  case direct = "Direct"

  public var id: String { rawValue }
}

public enum DashboardTUNStack: String, CaseIterable, Identifiable, Sendable {
  case mixed = "Mixed"
  case system = "System"
  case gvisor = "gVisor"

  public var id: String { rawValue }
}

public enum DashboardPortKind: String, CaseIterable, Identifiable, Sendable {
  case mixed = "Mixed"
  case http = "HTTP"
  case socks = "SOCKS"

  public var id: String { rawValue }
}

public struct DashboardConfiguration: Equatable, Sendable {
  public var mode: DashboardProxyMode
  public var enhancedTUNEnabled: Bool
  public var allowLAN: Bool
  public var unifiedDelay: Bool
  public var ipv6Enabled: Bool
  public var logLevel: ControllerLogLevel
  public var tcpConcurrent: Bool
  public var findProcessMode: ControllerFindProcessMode
  public var tunStack: DashboardTUNStack
  public var networkInterface: String
  public var mixedPort: Int
  public var httpPort: Int
  public var socksPort: Int

  public init(
    mode: DashboardProxyMode = .rule,
    enhancedTUNEnabled: Bool = true,
    allowLAN: Bool = false,
    unifiedDelay: Bool = true,
    ipv6Enabled: Bool = false,
    logLevel: ControllerLogLevel = .info,
    tcpConcurrent: Bool = false,
    findProcessMode: ControllerFindProcessMode = .strict,
    tunStack: DashboardTUNStack = .mixed,
    networkInterface: String = "Automatic",
    mixedPort: Int = 7890,
    httpPort: Int = 7891,
    socksPort: Int = 7892
  ) {
    self.mode = mode
    self.enhancedTUNEnabled = enhancedTUNEnabled
    self.allowLAN = allowLAN
    self.unifiedDelay = unifiedDelay
    self.ipv6Enabled = ipv6Enabled
    self.logLevel = logLevel
    self.tcpConcurrent = tcpConcurrent
    self.findProcessMode = findProcessMode
    self.tunStack = tunStack
    self.networkInterface = networkInterface
    self.mixedPort = mixedPort
    self.httpPort = httpPort
    self.socksPort = socksPort
  }
}

// MARK: - Sunset tokens

public enum DashboardTheme {
  public static let primary = Color(hex: 0xFF865B)
  public static let primaryContent = Color(hex: 0x160603)
  public static let secondary = Color(hex: 0xFD6F9C)
  public static let accent = Color(hex: 0xB387FA)
  public static let neutral = Color(hex: 0x1B262C)
  public static let background = Color(hex: 0x091319)
  public static let surface = Color(hex: 0x121C22)
  public static let surfaceRaised = Color(hex: 0x18252D)
  public static let divider = Color.white.opacity(0.08)
  public static let content = Color(hex: 0xD4E4F1)
  public static let muted = Color(hex: 0x9FB9D0)
  public static let info = Color(hex: 0x89E0EB)
  public static let success = Color(hex: 0xADDFAD)
  public static let warning = Color(hex: 0xF1C892)
  public static let error = Color(hex: 0xFFBBBD)

  public static let compactSpacing: CGFloat = 8
  public static let spacing: CGFloat = 16
  public static let sectionSpacing: CGFloat = 16
  public static let fieldRadius: CGFloat = 8
  public static let cardRadius: CGFloat = 12
}

extension Color {
  public init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: opacity
    )
  }
}

public enum DashboardFormat {
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .binary
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter
  }()

  public static func bytes(_ value: Int64) -> String {
    byteFormatter.string(fromByteCount: max(value, 0))
  }

  public static func speed(_ value: Int64) -> String {
    "\(bytes(value))/s"
  }

  public static func latency(_ value: Int?) -> String {
    guard let value else { return "—" }
    return "\(value) ms"
  }

  public static func duration(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, remainder) }
    return String(format: "%02d:%02d", minutes, remainder)
  }
}

// MARK: - Shared visual components

public struct DashboardPageHeader<Trailing: View>: View {
  private let title: String
  private let subtitle: String
  @ViewBuilder private let trailing: Trailing

  public init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  public var body: some View {
    HStack(alignment: .center, spacing: DashboardTheme.spacing) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(DashboardTheme.content)
        Text(subtitle)
          .font(.system(size: 13))
          .foregroundStyle(DashboardTheme.muted)
      }
      Spacer(minLength: DashboardTheme.spacing)
      trailing
    }
    .accessibilityElement(children: .contain)
  }
}

extension DashboardPageHeader where Trailing == EmptyView {
  public init(title: String, subtitle: String) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

public struct DashboardCard<Content: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .padding(DashboardTheme.spacing)
      .background(
        RoundedRectangle(cornerRadius: DashboardTheme.cardRadius, style: .continuous)
          .fill(hovering ? DashboardTheme.surfaceRaised : DashboardTheme.surface)
          .overlay {
            RoundedRectangle(cornerRadius: DashboardTheme.cardRadius, style: .continuous)
              .stroke(DashboardTheme.divider, lineWidth: 1)
          }
      )
      .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 12, y: 5)
      .offset(y: hovering && !reduceMotion ? -1 : 0)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
      .onHover { hovering = $0 }
  }
}

public struct MetricCard: View {
  private let title: String
  private let value: String
  private let symbol: String
  private let tint: Color

  public init(title: String, value: String, symbol: String, tint: Color) {
    self.title = title
    self.value = value
    self.symbol = symbol
    self.tint = tint
  }

  public var body: some View {
    DashboardCard {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 34, height: 34)
          .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DashboardTheme.muted)
          Text(value)
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DashboardTheme.content)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        Spacer(minLength: 0)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(value)")
  }
}

public struct DashboardPageStateView: View {
  private let state: DashboardLoadState
  private let emptyTitle: String
  private let retry: () -> Void

  public init(state: DashboardLoadState, emptyTitle: String, retry: @escaping () -> Void) {
    self.state = state
    self.emptyTitle = emptyTitle
    self.retry = retry
  }

  public var body: some View {
    VStack(spacing: 12) {
      switch state {
      case .loading:
        ProgressView()
          .controlSize(.large)
          .tint(DashboardTheme.primary)
        Text("Loading…")
          .foregroundStyle(DashboardTheme.muted)
      case .loaded:
        EmptyView()
      case .empty(let message):
        Image(systemName: "shippingbox")
          .font(.system(size: 28))
          .foregroundStyle(DashboardTheme.muted)
        Text(emptyTitle)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
        Text(message)
          .foregroundStyle(DashboardTheme.muted)
          .multilineTextAlignment(.center)
        Button("Refresh", action: retry)
          .buttonStyle(DashboardPrimaryButtonStyle())
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 28))
          .foregroundStyle(DashboardTheme.error)
        Text("Unable to load")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(DashboardTheme.content)
        Text(message)
          .foregroundStyle(DashboardTheme.muted)
          .multilineTextAlignment(.center)
        Button("Try Again", action: retry)
          .buttonStyle(DashboardPrimaryButtonStyle())
      }
    }
    .font(.system(size: 14))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
    .accessibilityElement(children: .contain)
  }
}

public struct DashboardPrimaryButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(DashboardTheme.primaryContent)
      .padding(.horizontal, 13)
      .padding(.vertical, 8)
      .background(
        DashboardTheme.primary.opacity(configuration.isPressed ? 0.72 : 1),
        in: RoundedRectangle(cornerRadius: DashboardTheme.fieldRadius)
      )
  }
}

public struct DashboardSecondaryButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(DashboardTheme.content)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        DashboardTheme.surfaceRaised.opacity(configuration.isPressed ? 0.65 : 1),
        in: RoundedRectangle(cornerRadius: DashboardTheme.fieldRadius)
      )
      .overlay {
        RoundedRectangle(cornerRadius: DashboardTheme.fieldRadius)
          .stroke(DashboardTheme.divider, lineWidth: 1)
      }
  }
}

public struct DashboardSearchField: View {
  private let prompt: String
  @Binding private var text: String

  public init(_ prompt: String, text: Binding<String>) {
    self.prompt = prompt
    self._text = text
  }

  public var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(DashboardTheme.muted)
        .accessibilityHidden(true)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .foregroundStyle(DashboardTheme.content)
        .accessibilityLabel(prompt)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardTheme.muted)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(
      DashboardTheme.surface, in: RoundedRectangle(cornerRadius: DashboardTheme.fieldRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DashboardTheme.fieldRadius)
        .stroke(DashboardTheme.divider, lineWidth: 1)
    }
  }
}

public struct DashboardSparkline: View {
  private let values: [Double]
  private let color: Color
  private let domain: ClosedRange<Double>?

  public init(values: [Double], color: Color, domain: ClosedRange<Double>? = nil) {
    self.values = values
    self.color = color
    self.domain = domain
  }

  public var body: some View {
    GeometryReader { geometry in
      let minimum = domain?.lowerBound ?? values.min() ?? 0
      let maximum = domain?.upperBound ?? values.max() ?? 1
      let spread = max(maximum - minimum, 1)
      Path { path in
        guard values.count > 1 else { return }
        for (index, value) in values.enumerated() {
          let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
          let ratio = (value - minimum) / spread
          let y = geometry.size.height * (1 - CGFloat(ratio))
          if index == 0 {
            path.move(to: CGPoint(x: x, y: y))
          } else {
            path.addLine(to: CGPoint(x: x, y: y))
          }
        }
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
    .accessibilityHidden(true)
  }
}

public struct StatusPill: View {
  private let text: String
  private let color: Color

  public init(_ text: String, color: Color) {
    self.text = text
    self.color = color
  }

  public var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
  }
}

extension DashboardRuntimeStatus {
  public var color: Color {
    switch self {
    case .connected: DashboardTheme.success
    case .degraded: DashboardTheme.warning
    case .disconnected: DashboardTheme.error
    }
  }
}

extension DashboardLogLevel {
  public var color: Color {
    switch self {
    case .all: DashboardTheme.muted
    case .debug: DashboardTheme.accent
    case .info: DashboardTheme.info
    case .warning: DashboardTheme.warning
    case .error: DashboardTheme.error
    }
  }
}
