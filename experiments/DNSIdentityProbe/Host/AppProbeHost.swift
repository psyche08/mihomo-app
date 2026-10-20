import Foundation
import NetworkExtension
import Security

// A separate VPN configuration in the existing independent test host.
// Controlled tests and explicit installed-AI-app sessions use separate rule sets.
final class AppProbeHost {
    private let extensionID = "dev.linsheng.mihomo-dns-probe.extension"
    private let identifiers = ["dev.linsheng.mihomo-dns-probe.selected",
                               "dev.linsheng.mihomo-dns-probe.selected.helper"]
    private var manager: NEAppProxyProviderManager?
    private var aiTargets: AIAppTargets?
    private var persistent = false

    private func finish(_ message: String, _ code: Int32 = 0) -> Never {
        print(message); fflush(stdout); exit(code)
    }

    func start(_ command: String) {
        if ["--app-ai-inventory", "--app-ai-session", "--app-ai-enable"].contains(command) {
            do { aiTargets = try AIAppTargets() } catch { finish("app_ai_target_discovery_failed", 1) }
            if command == "--app-ai-inventory" {
                let data = try! JSONSerialization.data(withJSONObject: aiTargets!.targets.map {
                    ["id": $0.id, "path": $0.path, "category": $0.category]
                }, options: [.prettyPrinted, .sortedKeys])
                finish(String(decoding: data, as: UTF8.self))
            }
            persistent = command == "--app-ai-enable"
        }
        NEAppProxyProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("app_preferences_error", 1) }
                let matches = (managers ?? []).filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID
                }
                guard matches.count <= 1 else { self.finish("app_ambiguous_configuration", 1) }
                self.manager = matches.first ?? NEAppProxyProviderManager.forPerAppVPN()
                // A newly allocated manager defaults to enabled even though no
                // configuration exists. Only saved managers represent state.
                if matches.isEmpty { self.manager!.isEnabled = false }
                if command == "--app-status" {
                    self.finish("app_probe_enabled=\(self.manager!.isEnabled); status=\(self.manager!.connection.status.rawValue); per_app=\(self.manager!.routingMethod == .sourceApplication)")
                } else if command == "--app-disable" {
                    if matches.isEmpty { self.finish("app_probe_disabled") }
                    self.disable()
                } else {
                    NEDNSProxyManager.shared().loadFromPreferences { error in
                        DispatchQueue.main.async {
                            guard error == nil, !NEDNSProxyManager.shared().isEnabled else {
                                self.finish("disable_dns_probe_before_app_probe", 1)
                            }
                            self.preparePerAppManager()
                        }
                    }
                }
            }
        }
    }

    private func preparePerAppManager() {
        guard let manager, !manager.isEnabled else { finish("app_already_enabled", 1) }
        if manager.routingMethod == .sourceApplication { enable(); return }
        // appRules are ignored for destination-IP routing. If an older test
        // saved that kind of record, replace only our disabled configuration.
        manager.removeFromPreferences { error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("app_legacy_configuration_remove_failed", 1) }
                self.manager = NEAppProxyProviderManager.forPerAppVPN()
                self.manager!.isEnabled = false
                self.enable()
            }
        }
    }

    private func rule(identifier: String, path: URL) -> NEAppRule? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let expected = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"89LGY6BD53\""
        var validation: SecRequirement?
        guard SecRequirementCreateWithString(expected as CFString, [], &validation) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], validation) == errSecSuccess else { return nil }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return NEAppRule(signingIdentifier: identifier, designatedRequirement: text as String)
    }

    private func enable() {
        guard let manager, !manager.isEnabled, manager.routingMethod == .sourceApplication else {
            finish("app_requires_source_application_routing", 1)
        }
        let selected = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Clients/MihomoDNSSelected.app")
        let paths = [selected, selected.appendingPathComponent("Contents/Library/LoginItems/MihomoDNSHelper.app")]
        let rules = aiTargets?.rules ?? zip(identifiers, paths).compactMap { rule(identifier: $0, path: $1) }
        guard aiTargets != nil || rules.count == identifiers.count else { finish("app_client_signature_invalid", 1) }
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = extensionID
        config.serverAddress = "Independent bounded App Proxy experiment"
        if let aiTargets {
            config.providerConfiguration = ["mode": "ai", "targets": aiTargets.targets.map(\.record),
                                            "deadline": persistent ? 0 : Date().timeIntervalSince1970 + 300]
        } else {
            config.providerConfiguration = ["deadline": Date().timeIntervalSince1970 + 300, "strictUnknown": true]
        }
        manager.protocolConfiguration = config
        manager.localizedDescription = aiTargets == nil ? "Mihomo App Proxy test (selected test clients only)" : "Mihomo App Proxy — ChatGPT, Codex, Claude"
        manager.appRules = rules
        manager.isEnabled = true
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("app_save_failed", 1) }
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        guard error == nil, manager.isEnabled,
                              manager.routingMethod == .sourceApplication,
                              self.sameRules(manager.appRules, rules),
                              (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID,
                              NSDictionary(dictionary: (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]).isEqual(to: config.providerConfiguration ?? [:]) else {
                            print("app_readback_failed"); self.disable(); return
                        }
                        do {
                            try manager.connection.startVPNTunnel()
                            print("app_probe_start_requested; persistent=\(self.persistent)"); fflush(stdout)
                            if self.persistent { self.confirmPersistentConnection(remaining: 30) } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 240) { self.disable() }
                            }
                        } catch {
                            print("app_start_failed"); self.disable()
                        }
                    }
                }
            }
        }
    }

    private func confirmPersistentConnection(remaining: Int) {
        guard let manager else { finish("app_manager_missing", 1) }
        if manager.connection.status == .connected { finish("app_ai_enabled; connected=true") }
        guard remaining > 0 else { print("app_ai_connect_timeout"); disable(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.confirmPersistentConnection(remaining: remaining - 1)
        }
    }

    private func sameRules(_ actual: [NEAppRule], _ expected: [NEAppRule]) -> Bool {
        guard actual.count == expected.count else { return false }
        for (a, b) in zip(actual, expected) {
            guard a.matchSigningIdentifier == b.matchSigningIdentifier else { return false }
            guard a.matchDesignatedRequirement == b.matchDesignatedRequirement else { return false }
            guard a.matchPath == b.matchPath else { return false }
            guard NSArray(array: a.matchDomains ?? []).isEqual(to: b.matchDomains ?? []) else { return false }
            guard sameRules(a.matchTools ?? [], b.matchTools ?? []) else { return false }
        }
        return true
    }

    private func disable() {
        guard let manager else { finish("app_manager_missing", 1) }
        manager.connection.stopVPNTunnel()
        manager.isEnabled = false
        manager.saveToPreferences { error in
            guard error == nil else { self.finish("app_disable_failed", 1) }
            manager.loadFromPreferences { error in
                guard error == nil, !manager.isEnabled else { self.finish("app_disable_readback_failed", 1) }
                self.finish("app_probe_disabled")
            }
        }
    }
}
