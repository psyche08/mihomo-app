import Foundation
import MihomoControl
import XCTest

@testable import MihomoBoxUI

final class LocalDoHProfileTests: XCTestCase {
  func testDomainPlanKeepsOnlyRepresentableProxyRulesAndCollapsesSuffixes() {
    let rules = [
      // Mihomo's controller API emits `DomainSuffix`, while YAML uses
      // `DOMAIN-SUFFIX`; the production planner must accept both forms.
      rule(0, "DomainSuffix", "Example.COM.", "Proxy"),
      rule(1, "DOMAIN-SUFFIX", "api.example.com", "Proxy"),
      rule(2, "DOMAIN", "claude.ai", "AI Services"),
      rule(3, "DOMAIN-SUFFIX", "direct.example", "DIRECT"),
      rule(4, "RULE-SET", "global-services", "Proxy"),
      rule(5, "DOMAIN-SUFFIX", "disabled.example", "Proxy", enabled: false),
      rule(6, "DOMAIN-SUFFIX", "bad domain", "Proxy"),
    ]

    let plan = LocalDoHDomainPlan.build(from: rules, routeSnapshot: proxyRoutes())

    XCTAssertEqual(plan.domains, ["claude.ai", "example.com"])
    XCTAssertEqual(plan.exactDomainApproximations, 1)
    XCTAssertEqual(plan.omittedRules, 2)
    XCTAssertEqual(plan.truncatedDomains, 0)
  }

  func testDomainPlanUsesCurrentProxyGroupSelectionAndFailsClosed() {
    let rules = [
      rule(0, "DOMAIN-SUFFIX", "proxied.example", "Remote Group"),
      rule(1, "DOMAIN-SUFFIX", "direct.example", "Direct Group"),
      rule(2, "DOMAIN-SUFFIX", "cycle.example", "Cycle A"),
      rule(3, "DOMAIN-SUFFIX", "missing.example", "Missing Group"),
      rule(4, "DOMAIN-SUFFIX", "leaf.example", "Node"),
    ]

    let plan = LocalDoHDomainPlan.build(from: rules, routeSnapshot: proxyRoutes())

    XCTAssertEqual(plan.domains, ["leaf.example", "proxied.example"])
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

  func testDashboardStatusDistinguishesApprovalActiveAndDegradedStates() {
    XCTAssertEqual(
      DashboardLocalDoHStatus(
        available: true,
        serverPrepared: true,
        runtimeHealthy: true
      ).phase,
      .awaitingApproval
    )
    XCTAssertEqual(
      DashboardLocalDoHStatus(
        available: true,
        serverPrepared: true,
        profileInstalled: true,
        runtimeHealthy: true
      ).phase,
      .active
    )
    XCTAssertEqual(
      DashboardLocalDoHStatus(
        available: true,
        serverPrepared: false,
        profileInstalled: true,
        runtimeHealthy: false
      ).phase,
      .degraded
    )
    XCTAssertEqual(
      DashboardLocalDoHStatus(available: true, statusVerified: false).phase,
      .statusUnavailable
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

  private func proxyRoutes() -> ControllerRouteSnapshot {
    ControllerRouteSnapshot(mode: "rule", proxies: [
      "Proxy": .init(name: "Proxy", type: "Selector", now: "Remote Group", all: ["Remote Group"]),
      "Remote Group": .init(name: "Remote Group", type: "Selector", now: "Node", all: ["Node", "DIRECT"]),
      "AI Services": .init(name: "AI Services", type: "Selector", now: "Node", all: ["Node"]),
      "Direct Group": .init(name: "Direct Group", type: "Selector", now: "DIRECT", all: ["DIRECT", "Node"]),
      "Cycle A": .init(name: "Cycle A", type: "Selector", now: "Cycle B", all: ["Cycle B"]),
      "Cycle B": .init(name: "Cycle B", type: "Selector", now: "Cycle A", all: ["Cycle A"]),
      "Node": .init(name: "Node", type: "VLESS"),
      "DIRECT": .init(name: "DIRECT", type: "Direct"),
    ])
  }
}
