import AppKit
import NetworkExtension
import SystemExtensions

final class ProbeHost: NSObject, OSSystemExtensionRequestDelegate {
    let manager = NEDNSProxyManager.shared()
    let extensionID = "dev.linsheng.mihomo-dns-probe.extension"
    func finish(_ code: Int32) -> Never { fflush(stdout); exit(code) }
    func load(_ body: @escaping () -> Void) {
        manager.loadFromPreferences { error in
            DispatchQueue.main.async {
                if let error = error as NSError? { print("preferences_error=\(error.domain):\(error.code)"); self.finish(1) }
                body()
            }
        }
    }
    func start(_ command: String) {
        if command == "--activate" || command == "--deactivate" {
            let r = command == "--activate" ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main) : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
            r.delegate = self; OSSystemExtensionManager.shared.submitRequest(r)
        } else if command == "--disable" {
            load { self.disable() }
        } else if command == "--session" || command == "--strict-session" {
            load {
                guard !self.manager.isEnabled else { print("already_enabled; disable_previous_session_first"); self.finish(1) }
                let config = NEDNSProxyProviderProtocol()
                config.providerBundleIdentifier = self.extensionID
                config.providerConfiguration = ["deadline": Date().timeIntervalSince1970+300, "strictUnknown": command == "--strict-session"]
                self.manager.providerProtocol = config
                self.manager.localizedDescription = "Mihomo DNS identity test (5 minutes)"
                self.manager.isEnabled = true
                self.manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error as NSError? { print("enable_error=\(error.domain):\(error.code)"); self.finish(1) }
                        // Read back the persisted configuration before reporting
                        // readiness to the test runner. Do not print its contents.
                        self.load {
                            let saved = self.manager.providerProtocol?.providerConfiguration
                            let deadline = saved?["deadline"] as? Double ?? 0
                            guard self.manager.isEnabled,
                                  self.manager.providerProtocol?.providerBundleIdentifier == self.extensionID,
                                  deadline > Date().timeIntervalSince1970,
                                  deadline <= Date().timeIntervalSince1970 + 330,
                                  saved?["strictUnknown"] as? Bool == (command == "--strict-session") else {
                                print("configuration_readback_failed"); fflush(stdout)
                                self.disable()
                                return
                            }
                            print("dns_probe_enabled; auto_disable_after=240s"); fflush(stdout)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now()+240) { self.load { self.disable() } }
                    }
                }
            }
        } else if command == "--status" {
            load { print("dns_probe_enabled=\(self.manager.isEnabled)"); self.finish(0) }
        } else {
            print("usage: MihomoDNSProbe --activate|--session|--strict-session|--disable|--status|--deactivate")
            finish(64)
        }
    }
    func disable() {
        manager.isEnabled = false
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                if let error = error as NSError? { print("disable_error=\(error.domain):\(error.code)"); self.finish(1) }
                print("dns_probe_disabled"); self.finish(0)
            }
        }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("system_extension_requires_user_approval"); fflush(stdout)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        print("system_extension_result=\(result.rawValue)"); finish(0)
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e=error as NSError; print("system_extension_error=\(e.domain):\(e.code)"); finish(1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = ProbeHost()
DispatchQueue.main.async { host.start(CommandLine.arguments.dropFirst().first ?? "--help") }
app.run()
withExtendedLifetime(host) {}
