import Foundation
import XCTest

@testable import MihomoBoxUI

final class LocalDoHProfileTests: XCTestCase {
  func testDomainPlanKeepsOnlyRepresentableProxyRulesAndCollapsesSuffixes() {
    let rules = [
      rule(0, "DOMAIN-SUFFIX", "Example.COM.", "Proxy"),
      rule(1, "DOMAIN-SUFFIX", "api.example.com", "Proxy"),
      rule(2, "DOMAIN", "claude.ai", "AI Services"),
      rule(3, "DOMAIN-SUFFIX", "direct.example", "DIRECT"),
      rule(4, "RULE-SET", "global-services", "Proxy"),
      rule(5, "DOMAIN-SUFFIX", "disabled.example", "Proxy", enabled: false),
      rule(6, "DOMAIN-SUFFIX", "bad domain", "Proxy"),
    ]

    let plan = LocalDoHDomainPlan.build(from: rules)

    XCTAssertEqual(plan.domains, ["claude.ai", "example.com"])
    XCTAssertEqual(plan.exactDomainApproximations, 1)
    XCTAssertEqual(plan.omittedRules, 2)
    XCTAssertEqual(plan.truncatedDomains, 0)
  }

  func testProfileUsesStableDeviceScopeSplitDNSPayload() throws {
    let plan = LocalDoHDomainPlan(domains: ["claude.ai", "example.com"])
    let data = try LocalDoHProfileDocument.data(for: plan)
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let profile = try XCTUnwrap(value as? [String: Any])
    XCTAssertEqual(profile["PayloadIdentifier"] as? String, LocalDoHProfileDocument.identifier)
    XCTAssertEqual(profile["PayloadScope"] as? String, "System")
    let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
    let settings = try XCTUnwrap(payloads.first?["DNSSettings"] as? [String: Any])
    XCTAssertEqual(settings["DNSProtocol"] as? String, "HTTPS")
    XCTAssertEqual(settings["ServerURL"] as? String, LocalDoHProfileDocument.serverURL)
    XCTAssertEqual(settings["ServerAddresses"] as? [String], ["127.0.0.1"])
    XCTAssertEqual(
      settings["SupplementalMatchDomains"] as? [String],
      ["claude.ai", "example.com"]
    )
  }

  func testEmptyPlanFailsInsteadOfBecomingGlobalDNS() {
    XCTAssertThrowsError(
      try LocalDoHProfileDocument.data(for: LocalDoHDomainPlan(domains: []))
    )
  }

  func testDeviceManagementUsesTheProfilesSystemSettingsDeepLink() {
    XCTAssertEqual(
      LocalDoHProfileDocument.deviceManagementURL.absoluteString,
      "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
    )
  }

  private func rule(
    _ index: Int,
    _ type: String,
    _ payload: String,
    _ target: String,
    enabled: Bool = true
  ) -> DashboardRule {
    DashboardRule(
      id: String(index),
      index: index,
      type: type,
      payload: payload,
      target: target,
      isEnabled: enabled
    )
  }
}
