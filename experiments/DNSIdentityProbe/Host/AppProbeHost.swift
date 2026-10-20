import Foundation
import NetworkExtension

// A separate VPN configuration in the existing independent test host.
// Only the controlled selected client and its signed helper are captured.
final class AppProbeHost {
    private let extensionID = "dev.linsheng.mihomo-dns-probe.extension"
    private let identifiers = ["dev.linsheng.mihomo-dns-probe.selected",
                               "dev.linsheng.mihomo-dns-probe.selected.helper"]
    private var manager: NEAppProxyProviderManager?

    private func finish(_ message: String, _ code: Int32 = 0) -> Never {
        print(message); fflush(stdout); exit(code)
    }

    func start(_ command: String) {
        NEAppProxyProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("app_preferences_error", 1) }
                let matches = (managers ?? []).filter {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID
                }
                guard matches.count <= 1 else { self.finish("app_ambiguous_configuration", 1) }
                self.manager = matches.first ?? NEAppProxyProviderManager()
                // A newly allocated manager defaults to enabled even though no
                // configuration exists. Only saved managers represent state.
                if matches.isEmpty { self.manager!.isEnabled = false }
                if command == "--app-status" {
                    self.finish("app_probe_enabled=\(self.manager!.isEnabled); status=\(self.manager!.connection.status.rawValue)")
                } else if command == "--app-disable" {
                    if matches.isEmpty { self.finish("app_probe_disabled") }
                    self.disable()
                } else {
                    NEDNSProxyManager.shared().loadFromPreferences { error in
                        DispatchQueue.main.async {
                            guard error == nil, !NEDNSProxyManager.shared().isEnabled else {
                                self.finish("disable_dns_probe_before_app_probe", 1)
                            }
                            self.enable()
                        }
                    }
                }
            }
        }
    }

    private func enable() {
        guard let manager, !manager.isEnabled else { finish("app_already_enabled", 1) }
        let config = NETunnelProviderProtocol()
        config.providerBundleIdentifier = extensionID
        config.serverAddress = "Independent bounded App Proxy experiment"
        config.providerConfiguration = ["deadline": Date().timeIntervalSince1970 + 300, "strictUnknown": true]
        manager.protocolConfiguration = config
        manager.localizedDescription = "Mihomo App Proxy test (selected test clients only)"
        manager.appRules = identifiers.map { identifier in
            NEAppRule(signingIdentifier: identifier, designatedRequirement:
                "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"89LGY6BD53\"")
        }
        manager.isEnabled = true
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                guard error == nil else { self.finish("app_save_failed", 1) }
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        guard error == nil, manager.isEnabled,
                              Set(manager.appRules.map(\.matchSigningIdentifier)) == Set(self.identifiers),
                              (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionID else {
                            print("app_readback_failed"); self.disable(); return
                        }
                        do {
                            try manager.connection.startVPNTunnel()
                            print("app_probe_start_requested; auto_disable_after=240s"); fflush(stdout)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 240) { self.disable() }
                        } catch {
                            print("app_start_failed"); self.disable()
                        }
                    }
                }
            }
        }
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
