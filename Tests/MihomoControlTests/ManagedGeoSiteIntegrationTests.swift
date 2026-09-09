import Foundation
import MihomoControl
import XCTest

final class ManagedGeoSiteIntegrationTests: XCTestCase {
  func testManagedM4MiniGeoSitePlan() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rulesPath = environment["MIHOMOBOX_TEST_CONTROLLER_RULES"],
      let snapshotPath = environment["MIHOMOBOX_TEST_CONTROLLER_SNAPSHOT"],
      let geoSitePath = environment["MIHOMOBOX_TEST_MANAGED_GEOSITE"]
    else {
      throw XCTSkip("managed GeoSite integration inputs were not requested")
    }

    let rules = try LocalDoHRouteRule.decodeControllerCatalog(
      Data(contentsOf: URL(fileURLWithPath: rulesPath))
    )
    let snapshotData = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    guard let snapshotObject = try JSONSerialization.jsonObject(with: snapshotData)
      as? [String: Any],
      let configs = snapshotObject["configs"],
      let proxies = snapshotObject["proxies"]
    else { throw LocalDoHPlanningError.invalidControllerRules }
    let snapshot = try ControllerRouteSnapshot(
      configsData: JSONSerialization.data(withJSONObject: configs),
      proxiesData: JSONSerialization.data(withJSONObject: proxies)
    )
    let database = try GeoSiteDatabase.loadManaged(path: geoSitePath)
    let plan = try LocalDoHDomainPlan.build(
      from: rules,
      routeSnapshot: snapshot,
      geoSiteDatabase: database
    )

    XCTAssertGreaterThan(plan.domains.count, 0)
    XCTAssertGreaterThan(plan.expandedGeoSiteRules, 0)
    XCTAssertFalse(plan.domains.contains("."))
    let encoded = try JSONEncoder().encode(plan.summary)
    XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: ".com"))
    print("MIHOMOBOX_LOCAL_DOH_PLAN_SUMMARY \(String(decoding: encoded, as: UTF8.self))")
  }
}
