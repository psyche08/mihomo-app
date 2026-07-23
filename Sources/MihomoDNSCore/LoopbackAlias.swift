import CMihomoDNSSystem
import Foundation

public enum LoopbackAliasError: Error, CustomStringConvertible {
    case operationFailed(String, Int32)

    public var description: String {
        switch self {
        case .operationFailed(let operation, let code):
            return "loopback alias \(operation) failed errno=\(-code)"
        }
    }
}

public final class LoopbackAliasManager: @unchecked Sendable {
    private let interfaceName: String
    private let address: String
    private let netmask: String
    private let markerPath: String

    public init(interfaceName: String, address: String, netmask: String, markerPath: String) {
        self.interfaceName = interfaceName
        self.address = address
        self.netmask = netmask
        self.markerPath = markerPath
    }

    public func isPresent() throws -> Bool {
        let result = mihomo_dns_interface_has_ipv4(interfaceName, address)
        guard result >= 0 else {
            throw LoopbackAliasError.operationFailed("inspect", result)
        }
        return result == 1
    }

    public func ensure() throws {
        if try isPresent() {
            return
        }
        let result = mihomo_dns_add_ipv4_alias(interfaceName, address, netmask)
        guard result == 0 else {
            throw LoopbackAliasError.operationFailed("add", result)
        }
        let markerURL = URL(fileURLWithPath: markerPath)
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("interface=\(interfaceName)\naddress=\(address)\n".utf8)
                .write(to: markerURL, options: .atomic)
        } catch {
            _ = mihomo_dns_remove_ipv4_alias(interfaceName, address)
            throw error
        }
        ServiceLog.info("event=loopback_alias_ready existing=false")
    }

    public func removeIfManaged() throws {
        guard FileManager.default.fileExists(atPath: markerPath) else { return }
        let result = mihomo_dns_remove_ipv4_alias(interfaceName, address)
        guard result == 0 else {
            throw LoopbackAliasError.operationFailed("remove", result)
        }
        try FileManager.default.removeItem(atPath: markerPath)
        ServiceLog.info("event=loopback_alias_removed")
    }
}
