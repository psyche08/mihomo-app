import Foundation
import Security
import XCTest
@testable import MihomoBoxApp

final class LocalDoHCertificateTrustTests: XCTestCase {
  func testPolicyIsSSLOnlyAndLoopbackScopedWithoutWritingTrust() throws {
    let settings = LocalDoHCertificateTrust.settings()
    XCTAssertEqual(settings.count, 3)
    XCTAssertEqual(settings[kSecTrustSettingsPolicyString as String] as? String, "127.0.0.1")
    XCTAssertEqual(settings[kSecTrustSettingsResult as String] as? UInt32,
                   SecTrustSettingsResult.trustRoot.rawValue)
    let policy = settings[kSecTrustSettingsPolicy as String] as! SecPolicy
    let properties = try XCTUnwrap(SecPolicyCopyProperties(policy)) as NSDictionary
    XCTAssertEqual(properties[kSecPolicyOid] as? String, kSecPolicyAppleSSL as String)
  }

  @MainActor
  func testProfileOpensEvenWhenTrustIsDeniedOrCancelled() async {
    for error in [CancellationError() as Error, NSError(domain: NSOSStatusErrorDomain, code: -60007)] {
      var opened = false
      do {
        try await LocalDoHPreparationFlow.finish(trust: { throw error }, openProfile: { opened = true })
        XCTFail("trust failure must not become success")
      } catch {}
      XCTAssertTrue(opened)
    }
  }

  @MainActor
  func testSuccessfulTrustStillRequiresOpeningProfile() async throws {
    var order: [String] = []
    try await LocalDoHPreparationFlow.finish(trust: { order.append("trust") },
                                           openProfile: { order.append("profile") })
    XCTAssertEqual(order, ["trust", "profile"])
  }

  func testInvalidCertificateCannotRequestAuthorization() async {
    do {
      try await LocalDoHCertificateTrust.authorize(Data())
      XCTFail("invalid CA must be rejected before invoking the system")
    } catch {}
  }
}
