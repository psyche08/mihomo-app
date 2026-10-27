import Foundation
import MihomoBoxUI
import MihomoControl

/// `mihomo-app --app-proxy ACTION [APP] [--approve]`: the signed host performs one App Proxy
/// action for `mihomoboxctl`, prints JSON and exits. Only the host owns the NetworkExtension
/// configuration and is accepted by the code-access broker. `--approve` is the operator's
/// consent to the scanned code and scopes, equivalent to confirming the sheet in the app.
@MainActor enum AppProxyCommand {
    static let argument = "--app-proxy"

    struct Invocation: Equatable {
        let action: String
        let application: String?
        let approve: Bool
    }

    struct UsageError: LocalizedError {
        var errorDescription: String? {
            "usage: --app-proxy status | flows | targets APP | enable APP [--approve] | disable APP | on | off"
        }
    }

    static func parse(_ arguments: [String]) throws -> Invocation {
        guard arguments.first == argument, arguments.count >= 2 else { throw UsageError() }
        let rest = Array(arguments.dropFirst(2))
        switch arguments[1] {
        case "status", "flows", "on", "off":
            guard rest.isEmpty else { throw UsageError() }
            return .init(action: arguments[1], application: nil, approve: false)
        case "targets", "disable":
            guard rest.count == 1 else { throw UsageError() }
            return .init(action: arguments[1], application: rest[0], approve: false)
        case "enable":
            guard rest.count == 1 || (rest.count == 2 && rest[1] == "--approve") else { throw UsageError() }
            return .init(action: "enable", application: rest[0], approve: rest.count == 2)
        default:
            throw UsageError()
        }
    }

    static func run(_ invocation: Invocation) async -> Int32 {
        let coordinator = AppProxyCoordinator(maintenance: false)
        do {
            let settings = try await ControlGateway().fetchAppProxyRouting().settings
            func entry() throws -> AppProxyEntry {
                guard let id = invocation.application, let entry = settings.applications.first(where: { $0.id == id }) else {
                    throw AppProxySettingsError.staleState
                }
                return entry
            }
            switch invocation.action {
            case "flows":
                guard let owners = await coordinator.flowOwners() else {
                    write(["error": "App Proxy is not connected or its provider did not answer"])
                    return 1
                }
                write(["flows": owners.flows.compactMap { flow -> [String: Any]? in
                    guard let owner = owners.owner(port: flow.port, udp: flow.udp) else { return nil }
                    return ["port": Int(flow.port), "network": flow.udp ? "udp" : "tcp", "pid": Int(flow.pid), "path": owner.path]
                }])
                return 0
            case "targets":
                let executables = try await coordinator.discoverExecutables(applications: [try entry()])
                write(["application": try entry().id, "executables": executables.map {
                    ["path": $0.path, "signingIdentifier": $0.signingIdentifier,
                     "teamIdentifier": $0.teamIdentifier.map { $0 as Any } ?? NSNull()] as [String: Any]
                }])
                return 0
            case "enable":
                try await coordinator.setApplicationEnabled(try entry().id, enabled: true, settings: settings,
                                                            interactive: invocation.approve)
            case "disable":
                try await coordinator.setApplicationEnabled(try entry().id, enabled: false, settings: settings)
            case "on", "off":
                try await coordinator.setEnabled(invocation.action == "on", settings: settings)
            default:
                break
            }
            write(summary(try await coordinator.status(settings: settings)))
            return 0
        } catch {
            write(["error": error.localizedDescription])
            return 1
        }
    }

    static func summary(_ status: AppProxyExtensionStatus) -> [String: Any] {
        [
            "available": status.available, "enabled": status.enabled, "connected": status.connected,
            "identityReady": status.identityReady, "verifiedTargets": status.verifiedTargetCount,
            "identityIssue": status.identityIssue.map { $0 as Any } ?? NSNull(),
            "discoveryIssues": status.discoveryIssues,
            // The same process-validation receipts as the app's diagnostics: PIDs and stages, no paths or traffic.
            "diagnostics": status.diagnostics.map { live in
                ["generation": live.generation?.uuidString as Any? ?? NSNull(), "counters": live.counters,
                 "recentFlows": live.recentFlows.map {
                     ["pid": $0.pid, "stage": $0.stage, "flow": String($0.flow.uuidString.prefix(8))] as [String: Any]
                 }] as [String: Any]
            } as Any? ?? NSNull(),
            "applications": status.applications.mapValues {
                ["requested": $0.requested, "active": $0.active, "issue": $0.issue.map { $0 as Any } ?? NSNull(),
                 "servicePaused": $0.servicePaused] as [String: Any]
            },
        ]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
