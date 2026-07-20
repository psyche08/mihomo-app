import Foundation

public struct Endpoint: Codable, Equatable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct ProxyConfiguration: Codable, Equatable {
    public var systemDNSListen: Endpoint
    public var mihomoDNS: Endpoint
    public var upstreamListen: Endpoint
    public var manageSystemDNS: Bool
    public var loopbackInterface: String
    public var loopbackAlias: String
    public var loopbackNetmask: String
    public var systemDNSBackupPath: String
    public var aliasMarkerPath: String
    public var queryTimeoutMilliseconds: Int
    public var fallbackDNSServers: [String]
    public var mihomoProcess: MihomoProcessConfiguration?
    public var controllerEndpoint: Endpoint?
    public var controllerSecret: String?

    public init(
        systemDNSListen: Endpoint = Endpoint(host: "127.0.0.53", port: 53),
        mihomoDNS: Endpoint = Endpoint(host: "127.0.0.1", port: 1153),
        upstreamListen: Endpoint = Endpoint(host: "127.0.0.1", port: 1054),
        manageSystemDNS: Bool = true,
        loopbackInterface: String = "lo0",
        loopbackAlias: String = "127.0.0.53",
        loopbackNetmask: String = "255.0.0.0",
        systemDNSBackupPath: String = "/Library/Application Support/Mihomo App/global-dns-backup.plist",
        aliasMarkerPath: String = "/Library/Application Support/Mihomo App/alias-created",
        queryTimeoutMilliseconds: Int = 5_000,
        fallbackDNSServers: [String] = [],
        mihomoProcess: MihomoProcessConfiguration? = nil,
        controllerEndpoint: Endpoint? = nil,
        controllerSecret: String? = nil
    ) {
        self.systemDNSListen = systemDNSListen
        self.mihomoDNS = mihomoDNS
        self.upstreamListen = upstreamListen
        self.manageSystemDNS = manageSystemDNS
        self.loopbackInterface = loopbackInterface
        self.loopbackAlias = loopbackAlias
        self.loopbackNetmask = loopbackNetmask
        self.systemDNSBackupPath = systemDNSBackupPath
        self.aliasMarkerPath = aliasMarkerPath
        self.queryTimeoutMilliseconds = queryTimeoutMilliseconds
        self.fallbackDNSServers = fallbackDNSServers
        self.mihomoProcess = mihomoProcess
        self.controllerEndpoint = controllerEndpoint
        self.controllerSecret = controllerSecret
    }

    public static func load(path: String) throws -> ProxyConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        guard systemDNSListen.port > 0, systemDNSListen.port <= 65_535,
              mihomoDNS.port > 0, mihomoDNS.port <= 65_535,
              upstreamListen.port > 0, upstreamListen.port <= 65_535 else {
            throw ConfigurationError.invalidPort
        }
        guard queryTimeoutMilliseconds >= 100, queryTimeoutMilliseconds <= 60_000 else {
            throw ConfigurationError.invalidTimeout
        }
        guard systemDNSListen != upstreamListen,
              systemDNSListen != mihomoDNS,
              mihomoDNS != upstreamListen else {
            throw ConfigurationError.recursiveEndpoint
        }
        if manageSystemDNS {
            guard systemDNSListen.host == loopbackAlias, systemDNSListen.port == 53 else {
                throw ConfigurationError.invalidSystemDNSListener
            }
        }
        if let controllerEndpoint {
            guard controllerEndpoint.host == "127.0.0.1",
                  controllerEndpoint.port > 0,
                  controllerEndpoint.port <= 65_535 else {
                throw ConfigurationError.invalidControllerEndpoint
            }
        }
        if let controllerSecret {
            if controllerSecret.count > 256 || controllerSecret.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) {
                throw ConfigurationError.invalidControllerSecret
            }
        }
    }
}

public struct MihomoProcessConfiguration: Codable, Equatable {
    public var binaryPath: String
    public var configDirectory: String
    public var configPath: String
    public var pidPath: String
    public var logPath: String
    public var restartDelayMilliseconds: Int

    public init(
        binaryPath: String = "/Library/Application Support/Mihomo App/mihomo",
        configDirectory: String = "/Library/Application Support/Mihomo App/mihomo-data",
        configPath: String = "/Library/Application Support/Mihomo App/mihomo-data/config.yaml",
        pidPath: String = "/Library/Application Support/Mihomo App/mihomo.pid",
        logPath: String = "/Library/Logs/Mihomo App/mihomo.log",
        restartDelayMilliseconds: Int = 1_000
    ) {
        self.binaryPath = binaryPath
        self.configDirectory = configDirectory
        self.configPath = configPath
        self.pidPath = pidPath
        self.logPath = logPath
        self.restartDelayMilliseconds = restartDelayMilliseconds
    }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
    case invalidPort
    case invalidTimeout
    case recursiveEndpoint
    case invalidSystemDNSListener
    case invalidControllerEndpoint
    case invalidControllerSecret

    public var description: String {
        switch self {
        case .invalidPort: return "port must be in 1...65535"
        case .invalidTimeout: return "query timeout must be in 100...60000 ms"
        case .recursiveEndpoint: return "ingress and upstream endpoints must be distinct"
        case .invalidSystemDNSListener: return "managed system DNS must listen on the configured loopback alias port 53"
        case .invalidControllerEndpoint: return "Mihomo controller must use a valid 127.0.0.1 port"
        case .invalidControllerSecret: return "Mihomo controller secret is invalid"
        }
    }
}
