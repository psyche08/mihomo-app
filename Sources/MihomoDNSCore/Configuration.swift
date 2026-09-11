import Foundation

public struct Endpoint: Codable, Equatable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

public struct LocalDoHConfiguration: Codable, Equatable {
    public var endpoint: Endpoint
    public var serverURL: String
    public var certificatePath: String
    public var privateKeyPath: String

    public init(
        endpoint: Endpoint = Endpoint(host: "127.0.0.1", port: 443),
        serverURL: String = "https://127.0.0.1/dns-query",
        certificatePath: String = "/Library/Application Support/Mihomo App/local-doh/server.crt",
        privateKeyPath: String = "/Library/Application Support/Mihomo App/local-doh/server.key"
    ) {
        self.endpoint = endpoint
        self.serverURL = serverURL
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
    }
}

public struct ProxyConfiguration: Codable, Equatable {
    public var systemDNSListen: Endpoint
    public var mihomoDNS: Endpoint
    public var upstreamListen: Endpoint
    public var manageSystemDNS: Bool
    /// Explicit compatibility mode used only when the fixed LocalHttpDns
    /// listener cannot start. macOS Global DNS points at Mihomo's Fake-IP
    /// gateway and therefore requires Enhanced TUN to remain enabled.
    public var globalDNSFallbackEnabled: Bool?
    /// Persisted desired TUN state. `nil` is accepted only for upgrades from
    /// older installations and means the previously always-on TUN behavior.
    public var enhancedTUNEnabled: Bool?
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
    public var localDoH: LocalDoHConfiguration?

    public init(
        systemDNSListen: Endpoint = Endpoint(host: "127.0.0.53", port: 53),
        mihomoDNS: Endpoint = Endpoint(host: "127.0.0.1", port: 1153),
        upstreamListen: Endpoint = Endpoint(host: "127.0.0.1", port: 1054),
        manageSystemDNS: Bool = true,
        globalDNSFallbackEnabled: Bool? = nil,
        enhancedTUNEnabled: Bool? = nil,
        loopbackInterface: String = "lo0",
        loopbackAlias: String = "127.0.0.53",
        loopbackNetmask: String = "255.0.0.0",
        systemDNSBackupPath: String = "/Library/Application Support/Mihomo App/global-dns-backup.plist",
        aliasMarkerPath: String = "/Library/Application Support/Mihomo App/alias-created",
        queryTimeoutMilliseconds: Int = 5_000,
        fallbackDNSServers: [String] = [],
        mihomoProcess: MihomoProcessConfiguration? = nil,
        controllerEndpoint: Endpoint? = nil,
        controllerSecret: String? = nil,
        localDoH: LocalDoHConfiguration? = nil
    ) {
        self.systemDNSListen = systemDNSListen
        self.mihomoDNS = mihomoDNS
        self.upstreamListen = upstreamListen
        self.manageSystemDNS = manageSystemDNS
        self.globalDNSFallbackEnabled = globalDNSFallbackEnabled
        self.enhancedTUNEnabled = enhancedTUNEnabled
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
        self.localDoH = localDoH
    }

    public static func load(path: String) throws -> ProxyConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var configuration = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
        // Accept only the former fixed endpoint during an in-place upgrade.
        // Normalizing before validation lets DNS restoration run with old
        // daemon.json bytes, without widening accepted paths or ports.
        let legacy = LocalDoHConfiguration(
            endpoint: Endpoint(host: "127.0.0.1", port: 9443),
            serverURL: "https://127.0.0.1:9443/dns-query"
        )
        if configuration.localDoH == legacy {
            configuration.localDoH = LocalDoHConfiguration()
        }
        try configuration.validate()
        return configuration
    }

    /// Where the agent publishes its runtime health for the daemon to serve.
    ///
    /// Derived from an existing managed path rather than stored, so adding it
    /// cannot break decoding of a daemon.json written by an older version —
    /// Codable synthesis would otherwise require the new key and the agent
    /// would fail to start after an upgrade.
    public var healthSnapshotPath: String {
        URL(fileURLWithPath: systemDNSBackupPath)
            .deletingLastPathComponent()
            .appendingPathComponent("runtime-health.json")
            .path
    }

    /// Root-only handoff used by the daemon to ask the already-running agent
    /// to restart its owned Mihomo child. The request carries the health
    /// generation that must appear after the restart, so a stale snapshot can
    /// never complete the daemon transaction.
    public var runtimeReloadRequestPath: String {
        URL(fileURLWithPath: systemDNSBackupPath)
            .deletingLastPathComponent()
            .appendingPathComponent("runtime-reload.json")
            .path
    }

    public var expectsEnhancedTUN: Bool {
        // Before this field existed every activated profile was started with
        // TUN enabled. Preserve that state for an in-place component upgrade;
        // newly installed configuration writes an explicit false.
        enhancedTUNEnabled ?? true
    }

    public var usesGlobalDNSFallback: Bool {
        globalDNSFallbackEnabled == true
    }

    public var managedSystemDNSServers: [String] {
        usesGlobalDNSFallback ? ["198.18.0.1"] : [systemDNSListen.host]
    }

    public var managedDNSProbeEndpoint: Endpoint {
        usesGlobalDNSFallback ? Endpoint(host: "198.18.0.1", port: 53) : systemDNSListen
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
        if let localDoH {
            // These values select the root daemon's local TLS endpoint. Keep
            // the surface fixed instead of accepting caller-selected ports or
            // file paths (including path traversal below local-doh/).
            guard localDoH == LocalDoHConfiguration(),
                  localDoH.endpoint != controllerEndpoint else {
                throw ConfigurationError.invalidLocalDoH
            }
            guard !manageSystemDNS else {
                throw ConfigurationError.incompatibleDNSOwnership
            }
        }
        if usesGlobalDNSFallback {
            guard manageSystemDNS,
                  localDoH == nil,
                  enhancedTUNEnabled == true else {
                throw ConfigurationError.incompatibleDNSOwnership
            }
        } else if enhancedTUNEnabled != nil {
            guard localDoH == LocalDoHConfiguration(), !manageSystemDNS else {
                throw ConfigurationError.incompatibleDNSOwnership
            }
        }
    }
}

public enum LocalDoHConfigurationStore {
    public static func ensureBaseService(configurationPath: String) throws {
        var configuration = try ProxyConfiguration.load(path: configurationPath)
        configuration.manageSystemDNS = false
        configuration.globalDNSFallbackEnabled = false
        configuration.localDoH = LocalDoHConfiguration()
        // Installing or migrating the base service must never preserve an
        // already-enabled tunnel. Certificate/profile approval is the explicit
        // prerequisite that later permits setEnhancedTUN(true).
        configuration.enhancedTUNEnabled = false
        try write(configuration, to: configurationPath)
    }

    public static func setEnhancedTUN(_ enabled: Bool, configurationPath: String) throws {
        var configuration = try ProxyConfiguration.load(path: configurationPath)
        configuration.manageSystemDNS = false
        configuration.globalDNSFallbackEnabled = false
        configuration.localDoH = LocalDoHConfiguration()
        configuration.enhancedTUNEnabled = enabled
        try write(configuration, to: configurationPath)
    }

    /// Restores the proven legacy ownership model when the local HTTPS
    /// endpoint cannot be kept alive. Global DNS is coupled to Enhanced TUN.
    public static func useGlobalDNSFallback(configurationPath: String) throws {
        var configuration = try ProxyConfiguration.load(path: configurationPath)
        configuration.manageSystemDNS = true
        configuration.localDoH = nil
        configuration.globalDNSFallbackEnabled = true
        configuration.enhancedTUNEnabled = true
        try write(configuration, to: configurationPath)
    }

    private static func write(_ configuration: ProxyConfiguration, to configurationPath: String) throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: URL(fileURLWithPath: configurationPath), options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationPath
        )
    }
}

/// Keeps restoration, ownership change, verified TUN startup and encrypted
/// profile removal in order. A failed new runtime always gets a verified stop.
public enum GlobalDNSFallbackTransition {
    public enum Failure: Error { case restoreUnconfirmed }

    public static func run(
        stopAndRestore: () -> Bool,
        configure: () throws -> Void,
        startAndValidate: () throws -> Void,
        finish: () -> Void
    ) throws {
        guard stopAndRestore() else { throw Failure.restoreUnconfirmed }
        do {
            try configure()
            try startAndValidate()
        } catch {
            guard stopAndRestore() else { throw Failure.restoreUnconfirmed }
            throw error
        }
        finish()
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
    case invalidLocalDoH
    case incompatibleDNSOwnership

    public var description: String {
        switch self {
        case .invalidPort: return "port must be in 1...65535"
        case .invalidTimeout: return "query timeout must be in 100...60000 ms"
        case .recursiveEndpoint: return "ingress and upstream endpoints must be distinct"
        case .invalidSystemDNSListener: return "managed system DNS must listen on the configured loopback alias port 53"
        case .invalidControllerEndpoint: return "Mihomo controller must use a valid 127.0.0.1 port"
        case .invalidControllerSecret: return "Mihomo controller secret is invalid"
        case .invalidLocalDoH: return "local DoH configuration is invalid"
        case .incompatibleDNSOwnership: return "local DoH and managed system DNS cannot be enabled together"
        }
    }
}
