import AppKit
import SystemExtensions

/// Operator-only entry point in the signed containing App. No VPN preferences,
/// code grants, daemon transactions or application interception are changed here.
@MainActor
final class AppProxyExtensionActivationCommand: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    static let argument = "--activate-app-proxy-extension"
    static let extensionID = "dev.linsheng.mihomo-app.app-proxy"
    struct Outcome: Encodable, Equatable {
        let status: String
        let errorCode: Int?
        var exitCode: Int32 {
            switch status {
            case "activated": return 0
            case "approvalRequired": return 2
            case "rebootRequired": return 3
            case "timedOut": return 4
            default: return 1
            }
        }
    }
    private var completion: ((Outcome) -> Void)?
    init(completion: @escaping (Outcome) -> Void) { self.completion = completion }

    func start() {
        guard getuid() != 0, Bundle.main.bundleIdentifier == "dev.linsheng.mihomo-app",
              Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/SystemExtensions/\(Self.extensionID).systemextension/Contents/MacOS/MihomoAppProxy").path) else {
            finish(.init(status: "unavailable", errorCode: nil)); return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.finish(.init(status: "timedOut", errorCode: nil))
        }
    }
    func finish(_ outcome: Outcome) {
        let callback = completion; completion = nil; callback?(outcome)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        finish(.init(status: "approvalRequired", errorCode: nil))
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard existing.bundleIdentifier == Self.extensionID, ext.bundleIdentifier == Self.extensionID else { return .cancel }
        return .replace
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        finish(.init(status: result == .completed ? "activated" : "rebootRequired", errorCode: nil))
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        finish(.init(status: "failed", errorCode: (error as NSError).code))
    }
}
