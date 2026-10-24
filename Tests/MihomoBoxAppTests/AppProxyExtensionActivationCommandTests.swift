import XCTest
import SystemExtensions
@testable import MihomoBoxApp

final class AppProxyExtensionActivationCommandTests: XCTestCase {
    @MainActor func testApprovalIsNotSuccessAndCompletesOnlyOnce() {
        var results: [AppProxyExtensionActivationCommand.Outcome] = []
        let command = AppProxyExtensionActivationCommand { results.append($0) }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AppProxyExtensionActivationCommand.extensionID, queue: .main)
        command.requestNeedsUserApproval(request)
        command.request(request, didFinishWithResult: .completed)
        command.finish(.init(status: "timedOut", errorCode: nil))
        XCTAssertEqual(results, [.init(status: "approvalRequired", errorCode: nil)])
        XCTAssertEqual(results.first?.exitCode, 2)
    }
    @MainActor func testFailureOutputNeverIncludesArbitraryErrorText() throws {
        var result: AppProxyExtensionActivationCommand.Outcome?
        let command = AppProxyExtensionActivationCommand { result = $0 }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AppProxyExtensionActivationCommand.extensionID, queue: .main)
        command.request(request, didFailWithError: NSError(domain: "private-domain", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "private-content"]))
        let value = try XCTUnwrap(result)
        let output = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertEqual(value.exitCode, 1)
        XCTAssertEqual(value.errorCode, 7)
        XCTAssertFalse(output.contains("private"))
    }
    @MainActor func testRebootIsDistinctFromCompletedActivation() {
        var result: AppProxyExtensionActivationCommand.Outcome?
        let command = AppProxyExtensionActivationCommand { result = $0 }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AppProxyExtensionActivationCommand.extensionID, queue: .main)
        command.request(request, didFinishWithResult: .willCompleteAfterReboot)
        XCTAssertEqual(result?.exitCode, 3)
        XCTAssertEqual(result?.status, "rebootRequired")
    }
}
