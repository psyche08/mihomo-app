import CMihomoDNSSystem
import Darwin
import Foundation

public enum OwnedTUNError: Error {
    case system(Int32)
    case invalidPlan
    case invalidInheritance
}

/// A parsed prefix retains the host address for interface assignment. Routes
/// use its network form. Prefix subtraction preserves upstream Darwin route
/// exclusions instead of replacing the machine's default route.
struct OwnedTUNPrefix: Hashable, Codable, Sendable {
    let bytes: [UInt8]
    let bits: Int
    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]) else { throw OwnedTUNError.invalidPlan }
        var storage = [UInt8](repeating: 0, count: 16)
        let family = parts[0].contains(":") ? AF_INET6 : AF_INET
        guard bits >= 0, bits <= (family == AF_INET ? 32 : 128),
              inet_pton(family, String(parts[0]), &storage) == 1 else { throw OwnedTUNError.invalidPlan }
        self.bytes = Array(storage.prefix(family == AF_INET ? 4 : 16)); self.bits = bits
    }
    private init(bytes: [UInt8], bits: Int) { self.bytes = bytes; self.bits = bits }
    var address: String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { _ = inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &output, socklen_t(output.count)) }
        return String(cString: output)
    }
    var network: Self {
        var masked = bytes
        for i in masked.indices {
            let remaining = max(0, min(8, bits-i*8))
            masked[i] &= remaining == 0 ? 0 : UInt8(255 << (8-remaining) & 255)
        }
        return Self(bytes: masked, bits: bits)
    }
    func contains(_ other: Self) -> Bool {
        bytes.count == other.bytes.count && bits <= other.bits
            && network.bytes == Self(bytes: other.bytes, bits: bits).network.bytes
    }
    func subtracting(_ other: Self) -> [Self] {
        if other.contains(self) { return [] }
        guard contains(other) else { return [network] }
        var right = network.bytes
        right[bits / 8] |= UInt8(1 << (7-bits%8))
        return Self(bytes: network.bytes, bits: bits+1).subtracting(other)
            + Self(bytes: right, bits: bits+1).subtracting(other)
    }
}

struct OwnedTUNPlan: Sendable {
    let addresses: [OwnedTUNPrefix]
    let routes: [OwnedTUNPrefix]
    let mtu: Int32
    init(controllerData: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: controllerData) as? [String: Any],
              let tun = object["tun"] as? [String: Any] else { throw OwnedTUNError.invalidPlan }
        func prefixes(_ keys: [String]) throws -> [OwnedTUNPrefix] {
            var result = [OwnedTUNPrefix]()
            for key in keys {
                guard let value = tun[key], !(value is NSNull) else { continue }
                guard let strings = value as? [String], strings.count <= 1024 else { throw OwnedTUNError.invalidPlan }
                result += try strings.map(OwnedTUNPrefix.init)
            }
            return result
        }
        addresses = try prefixes(["inet4-address", "inet6-address"])
        guard !addresses.isEmpty, addresses.count <= 16 else { throw OwnedTUNError.invalidPlan }
        let rawMTU = tun["mtu"] as? Int ?? 0
        guard rawMTU == 0 || (1280...65535).contains(rawMTU) else { throw OwnedTUNError.invalidPlan }
        mtu = Int32(rawMTU == 0 ? 9000 : rawMTU)
        let include = try prefixes(["route-address", "inet4-route-address", "inet6-route-address"])
        let exclude = try prefixes(["route-exclude-address", "inet4-route-exclude-address", "inet6-route-exclude-address"])
        var routes = [OwnedTUNPrefix]()
        if tun["auto-route"] as? Bool == true {
            for width in [4, 16] where addresses.contains(where: { $0.bytes.count == width }) {
                var ranges = include.filter { $0.bytes.count == width }.map(\.network)
                if ranges.isEmpty {
                    ranges = try (0..<8).map { n in
                        try OwnedTUNPrefix(width == 4 ? "\(1 << n).0.0.0/\(8-n)" : "\(String((1 << n) << 8, radix: 16))::/\(8-n)")
                    }
                } else {
                    ranges += addresses.filter { $0.bytes.count == width }.map(\.network)
                }
                for omission in exclude where omission.bytes.count == width {
                    ranges = ranges.flatMap { $0.subtracting(omission) }
                    guard ranges.count <= 4096 else { throw OwnedTUNError.invalidPlan }
                }
                for route in ranges {
                    if routes.contains(where: { $0.contains(route) }) { continue }
                    routes.removeAll { route.contains($0) }
                    routes.append(route)
                }
            }
        }
        self.routes = routes
    }
}

/// The daemon owns the primary descriptor; the agent and its sole kernel get
/// explicit inherited duplicates. No path or interface name can grant this
/// capability. The GUI never receives a descriptor.
public final class DaemonOwnedTUN: @unchecked Sendable {
    public static let statePath = "/Library/Application Support/Mihomo App/daemon-tun.json"
    public static let childDescriptor: Int32 = 3
    public let handle: FileHandle
    public let interfaceName: String
    private let lock = NSLock()
    private var routesActive = false
    private var attachmentPID: Int32?
    private var kernelPID: () -> Int32? = { nil }

    func bindKernel(_ provider: @escaping () -> Int32?) {
        lock.lock(); defer { lock.unlock() }
        kernelPID = provider
    }

    public init(create: Bool = true, inheritedDescriptor: Int32 = STDIN_FILENO) throws {
        let fd = create ? mihomo_owned_tun_create() : fcntl(inheritedDescriptor, F_DUPFD_CLOEXEC, 4)
        guard fd >= 0 else { throw OwnedTUNError.system(create ? fd : -errno) }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let result = mihomo_owned_tun_name(fd, &name, name.count)
        guard result == 0 else { close(fd); throw OwnedTUNError.system(result) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        interfaceName = String(cString: name)
    }

    public func publishOwner() throws {
        guard geteuid() == 0 else { throw OwnedTUNError.invalidInheritance }
        let data = try JSONSerialization.data(withJSONObject: ["interface": interfaceName, "owner": getpid()])
        try data.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.statePath)
    }

    public static func liveInterface(ownerPID: Int32? = nil) -> String? {
        var metadata = stat()
        guard lstat(statePath, &metadata) == 0, metadata.st_uid == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
              metadata.st_size > 0, metadata.st_size < 1024,
              let data = FileManager.default.contents(atPath: statePath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["interface"] as? String, name.hasPrefix("utun"),
              let pid = object["owner"] as? Int32,
              ownerPID == nil || ownerPID == pid,
              mihomo_dns_pid_executable_matches(pid, "/Library/Application Support/Mihomo App/mihomo-daemon") == 1,
              if_nametoindex(name) != 0 else { return nil }
        return name
    }

    /// Public controller projections expose interception, not the permanently
    /// attached internal listener. Never return its inherited descriptor.
    public static func publicControllerConfiguration(_ data: Data) throws -> Data {
        guard let name = liveInterface(),
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tun = object["tun"] as? [String: Any],
              tun["file-descriptor"] as? Int32 == childDescriptor,
              tun["device"] as? String == name else { return data }
        tun["enable"] = (tun["enable"] as? Bool == true)
            && MihomoRuntimeInspector.fakeIPRouteInterface() == name
        tun.removeValue(forKey: "file-descriptor")
        object["tun"] = tun
        return try JSONSerialization.data(withJSONObject: object)
    }

    public func deactivate() throws {
        lock.lock(); defer { lock.unlock() }
        let result = mihomo_owned_tun_clear(handle.fileDescriptor)
        guard result == 0 else { throw OwnedTUNError.system(result) }
        routesActive = false
    }

    public func suspend() throws {
        lock.lock(); defer { lock.unlock() }
        let result = mihomo_owned_tun_clear_routes(handle.fileDescriptor)
        guard result == 0 else { throw OwnedTUNError.system(result) }
        routesActive = false
    }

    /// The disabled listener's parsed configuration provides addresses without
    /// starting a second parser process. Mixed/system stacks need these local
    /// addresses before attaching, even in standby. No traffic routes yet.
    func prepareAttachment(_ plan: OwnedTUNPlan, permitted: () -> Bool = { true }) throws {
        lock.lock(); defer { lock.unlock() }
        guard permitted() else { throw OwnedTUNError.invalidInheritance }
        let cleared = mihomo_owned_tun_clear(handle.fileDescriptor)
        guard cleared == 0 else { throw OwnedTUNError.system(cleared) }
        routesActive = false
        let up = mihomo_owned_tun_set_up(handle.fileDescriptor, 1, plan.mtu)
        guard up == 0 else { throw OwnedTUNError.system(up) }
        for address in plan.addresses {
            let result = mihomo_owned_tun_address(handle.fileDescriptor, address.address, Int32(address.bits), 1)
            guard result == 0 else { _ = mihomo_owned_tun_clear(handle.fileDescriptor); throw OwnedTUNError.system(result) }
        }
    }

    func ensureRoutes(configuration: ProxyConfiguration) throws {
        lock.lock(); let active = routesActive; let pid = kernelPID(); let attached = attachmentPID; lock.unlock()
        guard let pid, let data = MihomoRuntimeInspector.rawControllerConfiguration(configuration: configuration),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tun = object["tun"] as? [String: Any],
              tun["file-descriptor"] as? Int32 == Self.childDescriptor,
              tun["device"] as? String == interfaceName else { return }
        let plan = try OwnedTUNPlan(controllerData: data)
        if attached != pid {
            // Mark before attempting: a failed core listener can close fd 3,
            // so recovery must launch a fresh child with a fresh duplicate.
            lock.lock(); attachmentPID = pid; lock.unlock()
            try prepareAttachment(plan, permitted: { self.kernelPID() == pid })
            guard let process = configuration.mihomoProcess else { throw OwnedTUNError.invalidInheritance }
            let file = URL(fileURLWithPath: process.configPath)
            let profile = try MihomoConfigurator.attachingDaemonTUN(String(contentsOf: file, encoding: .utf8), interfaceName: interfaceName)
            try Data(profile.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try MihomoRuntimeInspector.attachPrebuiltTUN(configuration: configuration)
            // Re-read after attachment. A successful HTTP response alone does
            // not prove that the listener accepted its inherited descriptor.
            try ensureRoutes(configuration: configuration)
            return
        }
        guard tun["enable"] as? Bool == true else { return }
        guard configuration.expectsEnhancedTUN else {
            if active { try suspend() }
            return
        }
        guard !active else { return }
        try activate(plan, permitted: { self.kernelPID() == pid })
    }

    func activate(_ plan: OwnedTUNPlan, permitted: () -> Bool = { true }) throws {
        lock.lock(); defer { lock.unlock() }
        // A controller response from a child that exited or was replaced must
        // never restore interception after that child's cleanup completed.
        guard permitted() else { return }
        func check(_ result: Int32) throws { if result != 0 { throw OwnedTUNError.system(result) } }
        do {
            try check(mihomo_owned_tun_clear_routes(handle.fileDescriptor))
            for route in plan.routes {
                // Darwin installs the IPv6 connected prefix with SIOCAIFADDR.
                // Keep that local-address route; adding a gateway duplicate
                // would fail with EEXIST even on our freshly allocated utun.
                if route.bytes.count == 16, plan.addresses.contains(where: { $0.network == route }) { continue }
                guard let gateway = plan.addresses.first(where: { $0.bytes.count == route.bytes.count }) else { throw OwnedTUNError.invalidPlan }
                try check(mihomo_owned_tun_route(handle.fileDescriptor, route.address, Int32(route.bits), gateway.address, 1))
            }
            routesActive = true
        } catch {
            _ = mihomo_owned_tun_clear_routes(handle.fileDescriptor)
            routesActive = false
            throw error
        }
    }

    /// The signed agent's exec-only entry consumes stdin, moves the utun to a
    /// known positive descriptor and restores normal stdin before exec. The
    /// Process wrapper retains PID, termination notifications and stderr logs.
    public static func execManagedMihomo() throws -> Never {
        let root = "/Library/Application Support/Mihomo App/"
        guard geteuid() == 0,
              mihomo_dns_pid_executable_matches(getppid(), root + "mihomo-agent") == 1 else { throw OwnedTUNError.invalidInheritance }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard mihomo_owned_tun_name(STDIN_FILENO, &name, name.count) == 0,
              String(cString: name) == liveInterface(),
              dup2(STDIN_FILENO, childDescriptor) == childDescriptor else { throw OwnedTUNError.invalidInheritance }
        let null = open("/dev/null", O_RDONLY)
        guard null >= 0, dup2(null, STDIN_FILENO) == STDIN_FILENO else { throw OwnedTUNError.invalidInheritance }
        if null != STDIN_FILENO && null != childDescriptor { close(null) }
        let values = [root + "mihomo", "-d", root + "mihomo-data", "-f", root + "mihomo-data/config.yaml"]
        let pointers = values.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        pointers.withUnsafeBufferPointer { _ = execv(values[0], $0.baseAddress!) }
        throw OwnedTUNError.system(-errno)
    }
}
