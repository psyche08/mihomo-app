import Foundation
import MihomoControl
import XCTest

@testable import MihomoBoxUI

final class LocalDoHProfileTests: XCTestCase {
  func testUnknownTrustAndUnverifiedProfileCannotSelectLocalDoH() {
    var status = DashboardLocalDoHStatus(
      available: true, serverPrepared: true, profileInstalled: true,
      runtimeHealthy: true
    )
    XCTAssertNil(status.confirmedDNSMode)
    XCTAssertNotEqual(status.phase, .active)
    status.certificateTrusted = true
    XCTAssertEqual(status.confirmedDNSMode, .localDoH)
    status.statusVerified = false
    XCTAssertNil(status.confirmedDNSMode)
    XCTAssertEqual(status.phase, .statusUnavailable)
  }
  func testInstalledProfileWithRejectedSSLTrustIsNeverActive() {
    XCTAssertEqual(DashboardLocalDoHStatus(
      available: true, serverPrepared: true, profileInstalled: true,
      runtimeHealthy: false, certificateTrusted: false
    ).phase, .certificateUntrusted)
    XCTAssertEqual(DashboardLocalDoHStatus(
      available: true, serverPrepared: true, runtimeHealthy: false,
      certificateTrusted: false
    ).phase, .awaitingApproval)
  }
  func testFallbackDistinguishesActiveStoppedAndPendingProfileRemoval() {
    XCTAssertEqual(DashboardLocalDoHStatus(
      available: true, systemDNSManaged: true, globalDNSFallback: true
    ).phase, .globalDNSFallback)
    XCTAssertEqual(DashboardLocalDoHStatus(
      available: true, systemDNSManaged: false, globalDNSFallback: true
    ).phase, .fallbackUnavailable)
    XCTAssertEqual(DashboardLocalDoHStatus(
      available: true, statusVerified: false, systemDNSManaged: true,
      globalDNSFallback: true, fallbackProfileRemovalRequired: true
    ).phase, .fallbackNeedsProfileRemoval)
  }
  func testProxyGeoSiteRuleExpandsAttributesAndCountsUnrepresentableEntries() throws {
    let database = GeoSiteDatabase(sites: [
      "category-ai-!cn": [
        .init(type: .rootDomain, value: "service.example", attributes: ["global"]),
        .init(type: .full, value: "host.other.example", attributes: ["global"]),
        .init(type: .plain, value: "keyword", attributes: ["global"]),
        .init(type: .regex, value: ".*\\.regex\\.example", attributes: ["global"]),
        .init(type: .rootDomain, value: "excluded.example", attributes: ["cn"]),
      ]
    ])
    let plan = try LocalDoHDomainPlan.build(
      from: [rule("GEOSITE", "geosite:category-ai-!cn@global", "Proxy")],
      routeSnapshot: proxyRoutes(),
      geoSiteDatabase: database
    )

    XCTAssertEqual(plan.domains, ["service.example", "host.other.example"])
    XCTAssertEqual(plan.expandedGeoSiteRules, 1)
    XCTAssertEqual(plan.unrepresentableGeoSiteEntries, 2)
    XCTAssertEqual(plan.exactDomainApproximations, 1)
    XCTAssertEqual(plan.omittedRules, 0)
  }

  func testGeoSiteAttributeFiltersUseIntersectionAndLeadingBangDoesNotBecomeGlobal() throws {
    let database = GeoSiteDatabase(sites: [
      "sample": [
        .init(type: .rootDomain, value: "both.example", attributes: ["one", "two"]),
        .init(type: .rootDomain, value: "one.example", attributes: ["one"]),
      ]
    ])
    let plan = try LocalDoHDomainPlan.build(
      from: [
        rule("GEOSITE", "sample@one@two", "Proxy"),
        rule("GEOSITE", "!sample", "Proxy"),
      ],
      routeSnapshot: proxyRoutes(),
      geoSiteDatabase: database
    )

    XCTAssertEqual(plan.domains, ["both.example"])
    XCTAssertEqual(plan.expandedGeoSiteRules, 1)
    XCTAssertEqual(plan.invertedGeoSiteRules, 1)
    XCTAssertEqual(plan.omittedRules, 1)
    XCTAssertFalse(plan.domains.contains("."))
  }

  func testGeoSitePlanDoesNotSilentlyTruncateBeyondFormerLimit() throws {
    let entries = (0..<5_000).map {
      GeoSiteDatabase.Entry(type: .rootDomain, value: "d\($0).example")
    }
    let plan = try LocalDoHDomainPlan.build(
      from: [rule("GEOSITE", "large", "Proxy")],
      routeSnapshot: proxyRoutes(),
      geoSiteDatabase: GeoSiteDatabase(sites: ["large": entries])
    )

    XCTAssertEqual(plan.domains.count, 5_000)
    XCTAssertEqual(plan.summary.domainCount, 5_000)
  }

  func testDirectUnknownAndCyclicGeoSiteTargetsFailClosedWithoutLoadingLists() throws {
    let plan = try LocalDoHDomainPlan.build(
      from: [
        rule("DOMAIN-SUFFIX", "safe.example", "Proxy"),
        rule("GEOSITE", "missing-direct", "DIRECT"),
        rule("GEOSITE", "missing-unknown", "Missing Group"),
        rule("GEOSITE", "missing-cycle", "Cycle A"),
      ],
      routeSnapshot: proxyRoutes(),
      geoSiteDatabase: nil
    )

    XCTAssertEqual(plan.domains, ["safe.example"])
    XCTAssertEqual(plan.expandedGeoSiteRules, 0)
  }

  func testMissingProxiedGeoSiteListFailsInsteadOfWritingPartialProfile() {
    XCTAssertThrowsError(
      try LocalDoHDomainPlan.build(
        from: [rule("GEOSITE", "missing", "Proxy")],
        routeSnapshot: proxyRoutes(),
        geoSiteDatabase: GeoSiteDatabase(sites: ["other": []])
      )
    ) { error in
      XCTAssertEqual(error as? LocalDoHPlanningError, .geoSiteListMissing)
    }
  }

  func testProtobufGeoSiteDecoderPreservesTypesAndAttributeKeys() throws {
    let data = message(field: 1, value: site(
      code: "Sample",
      domains: [
        domain(type: 2, value: "suffix.example", attributes: ["cn"]),
        domain(type: 3, value: "full.example"),
        domain(type: 0, value: "keyword"),
        domain(type: 1, value: ".*regex"),
      ]
    ))
    let database = try GeoSiteDatabase.decode(data)
    let plan = try LocalDoHDomainPlan.build(
      from: [rule("GEOSITE", "sample@CN", "Proxy")],
      routeSnapshot: proxyRoutes(),
      geoSiteDatabase: database
    )

    XCTAssertEqual(plan.domains, ["suffix.example"])
    XCTAssertEqual(plan.unrepresentableGeoSiteEntries, 0)
  }

  func testMalformedGeoSiteProtobufFailsClosed() {
    XCTAssertThrowsError(try GeoSiteDatabase.decode(Data([0x0f]))) { error in
      XCTAssertEqual(error as? LocalDoHPlanningError, .invalidGeoSiteDatabase)
    }
  }

  func testDomainPlanKeepsOnlyRepresentableProxyRulesAndCollapsesSuffixes() throws {
    let rules = [
      rule("DomainSuffix", "Example.COM.", "Proxy"),
      rule("DOMAIN-SUFFIX", "api.example.com", "Proxy"),
      rule("DOMAIN", "claude.ai", "AI Services"),
      rule("DOMAIN-SUFFIX", "direct.example", "DIRECT"),
      rule("RULE-SET", "global-services", "Proxy"),
      rule("DOMAIN-SUFFIX", "disabled.example", "Proxy", enabled: false),
      rule("DOMAIN-SUFFIX", "bad domain", "Proxy"),
    ]

    let plan = try LocalDoHDomainPlan.build(from: rules, routeSnapshot: proxyRoutes())

    XCTAssertEqual(plan.domains, ["claude.ai", "example.com"])
    XCTAssertEqual(plan.exactDomainApproximations, 1)
    XCTAssertEqual(plan.omittedRules, 2)
  }

  func testDomainPlanUsesCurrentProxyGroupSelectionAndFailsClosed() throws {
    let rules = [
      rule("DOMAIN-SUFFIX", "proxied.example", "Remote Group"),
      rule("DOMAIN-SUFFIX", "direct.example", "Direct Group"),
      rule("DOMAIN-SUFFIX", "cycle.example", "Cycle A"),
      rule("DOMAIN-SUFFIX", "missing.example", "Missing Group"),
      rule("DOMAIN-SUFFIX", "leaf.example", "Node"),
    ]

    let plan = try LocalDoHDomainPlan.build(from: rules, routeSnapshot: proxyRoutes())

    XCTAssertEqual(plan.domains, ["leaf.example", "proxied.example"])
  }

  func testProfileUsesStableRootOwnedDeviceScopeSplitDNSPayload() throws {
    let plan = LocalDoHDomainPlan(domains: ["claude.ai", "example.com"])
    let rootCertificate = Data([0x30, 0x03, 0x02, 0x01, 0x00])
    let data = try LocalDoHProfileDocument.data(
      for: plan,
      rootCertificate: rootCertificate
    )
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let profile = try XCTUnwrap(value as? [String: Any])
    XCTAssertEqual(profile["PayloadIdentifier"] as? String, LocalDoHProfileDocument.identifier)
    XCTAssertEqual(profile["PayloadScope"] as? String, "System")
    XCTAssertEqual(
      LocalDoHProfileDocument.managedProfilePath,
      "/Library/Application Support/Mihomo App/MihomoBox-Local-DoH.mobileconfig"
    )
    let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
    XCTAssertEqual(payloads.count, 2)
    let certificatePayload = try XCTUnwrap(payloads.first(where: {
      $0["PayloadType"] as? String == "com.apple.security.root"
    }))
    XCTAssertEqual(
      certificatePayload["PayloadIdentifier"] as? String,
      LocalDoHProfileDocument.rootCertificatePayloadIdentifier
    )
    XCTAssertEqual(certificatePayload["PayloadContent"] as? Data, rootCertificate)
    let dnsPayload = try XCTUnwrap(payloads.first(where: {
      $0["PayloadType"] as? String == "com.apple.dnsSettings.managed"
    }))
    let settings = try XCTUnwrap(dnsPayload["DNSSettings"] as? [String: Any])
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
      try LocalDoHProfileDocument.data(
        for: LocalDoHDomainPlan(domains: []),
        rootCertificate: Data([0x01])
      )
    )
  }

  func testDashboardStatusDistinguishesApprovalActiveAndDegradedStates() {
    XCTAssertEqual(
      DashboardLocalDoHStatus(available: true, serverPrepared: true, runtimeHealthy: true).phase,
      .awaitingApproval
    )
    XCTAssertEqual(
      DashboardLocalDoHStatus(
        available: true,
        serverPrepared: true,
        profileInstalled: true,
        runtimeHealthy: true,
        certificateTrusted: true
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
    _ type: String,
    _ payload: String,
    _ target: String,
    enabled: Bool = true
  ) -> LocalDoHRouteRule {
    LocalDoHRouteRule(type: type, payload: payload, target: target, isEnabled: enabled)
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

  private func domain(type: UInt64, value: String, attributes: [String] = []) -> Data {
    var valueData = varintField(1, type)
    valueData.append(message(field: 2, value: Data(value.utf8)))
    for attribute in attributes {
      valueData.append(message(field: 3, value: message(field: 1, value: Data(attribute.utf8))))
    }
    return valueData
  }

  private func site(code: String, domains: [Data]) -> Data {
    var value = message(field: 1, value: Data(code.utf8))
    for domain in domains { value.append(message(field: 2, value: domain)) }
    return value
  }

  private func message(field: UInt64, value: Data) -> Data {
    var data = encodeVarint(field << 3 | 2)
    data.append(encodeVarint(UInt64(value.count)))
    data.append(value)
    return data
  }

  private func varintField(_ field: UInt64, _ value: UInt64) -> Data {
    var data = encodeVarint(field << 3)
    data.append(encodeVarint(value))
    return data
  }

  private func encodeVarint(_ value: UInt64) -> Data {
    var value = value
    var data = Data()
    repeat {
      var byte = UInt8(value & 0x7f)
      value >>= 7
      if value != 0 { byte |= 0x80 }
      data.append(byte)
    } while value != 0
    return data
  }
}
