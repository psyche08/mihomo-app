import Foundation
import XCTest

@testable import MihomoBoxUI

final class ControllerModelsTests: XCTestCase {
  private let decoder = JSONDecoder()

  func testVersionDefaultsMissingFieldsAndIgnoresUnknownFields() throws {
    let version = try decode(
      ControllerVersion.self,
      #"{"version":"v1.19.12","future":{"channel":"stable"}}"#
    )

    XCTAssertEqual(version.version, "v1.19.12")
    XCTAssertFalse(version.meta)
  }

  func testConfigDecodesManagedReadOnlySectionsWithoutRequiringEveryField() throws {
    let config = try decode(
      ControllerConfig.self,
      """
      {
        "mode": "rule",
        "tun": {
          "enable": true,
          "stack": "mixed",
          "dns-hijack": null,
          "future": "ignored"
        },
        "dns": {
          "enable": true,
          "enhanced-mode": "fake-ip",
          "nameserver": ["127.0.0.1:1054"],
          "future": true
        },
        "UnifiedDelay": true,
        "unknown-top-level": 42
      }
      """
    )

    XCTAssertEqual(config.mode, "rule")
    XCTAssertTrue(config.tun.enable)
    XCTAssertEqual(config.tun.stack, "mixed")
    XCTAssertEqual(config.tun.dnsHijack, [])
    XCTAssertEqual(config.dns?.enhancedMode, "fake-ip")
    XCTAssertEqual(config.dns?.nameserver, ["127.0.0.1:1054"])
    XCTAssertEqual(config.unifiedDelay, true)
    XCTAssertFalse(config.allowLAN)
  }

  func testProxyCatalogUsesDictionaryKeyWhenNameIsMissingAndPreservesExtraJSON() throws {
    let catalog = try decode(
      ControllerProxyCatalog.self,
      """
      {
        "proxies": {
          "Auto": {
            "type": "Selector",
            "all": ["Node A"],
            "now": "Node A",
            "history": [{"time":"2026-08-11T00:00:00Z","delay":88,"ignored":1}],
            "extra": {"nested":{"ready":true},"attempts":3},
            "future": "ignored"
          },
          "Node A": {"name":"Node A","type":"VLESS"}
        },
        "future": []
      }
      """
    )

    XCTAssertEqual(catalog.proxies["Auto"]?.name, "Auto")
    XCTAssertEqual(catalog.proxies["Auto"]?.all, ["Node A"])
    XCTAssertEqual(catalog.proxies["Auto"]?.history.first?.delay, 88)
    XCTAssertEqual(catalog.proxies["Auto"]?.extra["attempts"], .integer(3))
    XCTAssertEqual(
      catalog.proxies["Auto"]?.extra["nested"],
      .object(["ready": .bool(true)])
    )
    XCTAssertFalse(catalog.proxies["Node A"]?.udp ?? true)
  }

  func testProviderCatalogDefaultsFieldsAndUsesDictionaryName() throws {
    let catalog = try decode(
      ControllerProxyProviderCatalog.self,
      """
      {
        "providers": {
          "subscription": {
            "subscriptionInfo": {"Download":12,"Upload":34,"Total":5000000000},
            "proxies": [{"name":"Node A","alive":true}],
            "updatedAt": "2026-08-11T00:00:00Z",
            "future": "ignored"
          }
        }
      }
      """
    )

    let provider = try XCTUnwrap(catalog.providers["subscription"])
    XCTAssertEqual(provider.name, "subscription")
    XCTAssertEqual(provider.subscriptionInfo?.total, 5_000_000_000)
    XCTAssertEqual(provider.proxies.first?.alive, true)
    XCTAssertEqual(provider.vehicleType, "")
  }

  func testRuleDictionaryDerivesIndicesAndToleratesMissingFields() throws {
    let catalog = try decode(
      ControllerRuleCatalog.self,
      """
      {
        "rules": {
          "7": {
            "type":"DOMAIN-SUFFIX",
            "payload":"example.com",
            "proxy":"Proxy",
            "extra":{"disabled":true,"hitCount":5000000000,"future":1}
          },
          "2": {"type":"MATCH","proxy":"DIRECT","future":true}
        },
        "future": "ignored"
      }
      """
    )

    XCTAssertEqual(catalog.rules.map(\.index), [2, 7])
    XCTAssertEqual(catalog.rules[0].payload, "")
    XCTAssertEqual(catalog.rules[1].extra?.disabled, true)
    XCTAssertEqual(catalog.rules[1].extra?.hitCount, 5_000_000_000)
  }

  func testRuleProviderCatalogUsesDictionaryKeyAndIgnoresExtraFields() throws {
    let catalog = try decode(
      ControllerRuleProviderCatalog.self,
      """
      {
        "providers": {
          "private": {
            "behavior":"domain",
            "format":"mrs",
            "ruleCount":1024,
            "vehicleType":"HTTP",
            "future":{"ignored":true}
          }
        }
      }
      """
    )

    XCTAssertEqual(catalog.providers["private"]?.name, "private")
    XCTAssertEqual(catalog.providers["private"]?.ruleCount, 1_024)
    XCTAssertEqual(catalog.providers["private"]?.updatedAt, "")
  }

  func testConnectionsFrameSupportsLargeCountersMissingMetadataAndNullFrames() throws {
    let frame = try decode(
      ControllerConnectionsFrame.self,
      """
      {
        "connections": [{
          "id":"connection-1",
          "download":5000000001,
          "chains":["Proxy"],
          "metadata":{"host":"example.com","uid":501,"future":true},
          "future":"ignored"
        }],
        "uploadTotal":6000000002,
        "downloadTotal":7000000003,
        "future":true
      }
      """
    )

    XCTAssertEqual(frame.uploadTotal, 6_000_000_002)
    XCTAssertEqual(frame.downloadTotal, 7_000_000_003)
    XCTAssertEqual(frame.connections.first?.download, 5_000_000_001)
    XCTAssertEqual(frame.connections.first?.upload, 0)
    XCTAssertEqual(frame.connections.first?.metadata.host, "example.com")
    XCTAssertEqual(frame.connections.first?.metadata.sourceIP, "")

    let nullFrame = try decode(ControllerConnectionsFrame.self, "null")
    XCTAssertEqual(nullFrame, ControllerConnectionsFrame())
  }

  func testAllStreamFrameDTOsDefaultMissingFieldsAndIgnoreAdditionalFields() throws {
    let traffic = try decode(
      ControllerTrafficFrame.self,
      #"{"down":9000000000,"future":1}"#
    )
    let memory = try decode(
      ControllerMemoryFrame.self,
      #"{"inuse":123,"oslimit":456,"future":789}"#
    )
    let log = try decode(
      ControllerLogFrame.self,
      #"{"type":"warning","payload":"request timed out","future":true}"#
    )

    XCTAssertEqual(traffic.up, 0)
    XCTAssertEqual(traffic.down, 9_000_000_000)
    XCTAssertEqual(memory, ControllerMemoryFrame(inuse: 123, oslimit: 456))
    XCTAssertEqual(log, ControllerLogFrame(type: "warning", payload: "request timed out"))
  }

  func testSnapshotCombinesConfigAndProxyEnvelopes() throws {
    let snapshot = try decode(
      ControllerSnapshot.self,
      """
      {
        "configs":{"mode":"direct"},
        "proxies":{"proxies":{"DIRECT":{"type":"Direct"}}},
        "future":true
      }
      """
    )

    XCTAssertEqual(snapshot.configs.mode, "direct")
    XCTAssertEqual(snapshot.proxies.proxies["DIRECT"]?.name, "DIRECT")
  }

  func testRuntimeConfigPatchCannotEncodeManagedControllerDNSOrTUNKeys() throws {
    let patches: [RuntimeConfigPatch] = [
      .allowLAN(true),
      .ipv6(false),
      .logLevel(.warning),
      .unifiedDelay(true),
      .tcpConcurrent(true),
      .findProcessMode(.strict),
    ]
    let forbidden = Set([
      "external-controller", "secret", "authentication", "dns", "tun",
    ])

    for patch in patches {
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: patch.encodedPayload()) as? [String: Any]
      )
      XCTAssertTrue(forbidden.isDisjoint(with: object.keys))
      XCTAssertEqual(object.count, 1)
    }
  }

  func testGlobalModeChoosesARealProxyAndRejectsCyclesOrDirectBuiltins() throws {
    let safe = try decode(
      ControllerSnapshot.self,
      """
      {
        "configs":{"mode":"rule"},
        "proxies":{"proxies":{
          "GLOBAL":{"type":"Selector","now":"DIRECT","all":["DIRECT","Auto","Node"]},
          "Auto":{"type":"Selector","now":"Node","all":["Node"]},
          "Node":{"type":"VLESS"},
          "DIRECT":{"type":"Direct"}
        }}
      }
      """
    )
    XCTAssertEqual(safe.globalProxyTarget, "Auto")
    XCTAssertFalse(safe.globalRoutesThroughProxy)

    let cycle = try decode(
      ControllerSnapshot.self,
      """
      {
        "configs":{"mode":"global"},
        "proxies":{"proxies":{
          "GLOBAL":{"type":"Selector","now":"A","all":["A","REJECT"]},
          "A":{"type":"Selector","now":"B","all":["B"]},
          "B":{"type":"Selector","now":"A","all":["A"]}
        }}
      }
      """
    )
    XCTAssertNil(cycle.globalProxyTarget)
    XCTAssertFalse(cycle.globalRoutesThroughProxy)
  }

  func testNestedSelectionCannotBreakAnActiveGlobalRoute() throws {
    let snapshot = try decode(
      ControllerSnapshot.self,
      """
      {
        "configs":{"mode":"global"},
        "proxies":{"proxies":{
          "GLOBAL":{"type":"Selector","now":"Auto","all":["Auto"]},
          "Auto":{"type":"Selector","now":"Node","all":["Node","DIRECT"]},
          "Node":{"type":"VLESS"},
          "DIRECT":{"type":"Direct"}
        }}
      }
      """
    )
    XCTAssertTrue(snapshot.globalRoutesThroughProxy)
    XCTAssertEqual(
      snapshot.selecting(group: "Auto", proxy: "Node")?.globalRoutesThroughProxy,
      true
    )
    XCTAssertEqual(
      snapshot.selecting(group: "Auto", proxy: "DIRECT")?.globalRoutesThroughProxy,
      false
    )
    XCTAssertNil(snapshot.selecting(group: "Auto", proxy: "Missing"))
  }

  func testGlobalRouteNamesAreCaseSensitiveAndMissingTargetsFailClosed() throws {
    let snapshot = try decode(
      ControllerSnapshot.self,
      """
      {
        "configs":{"mode":"global"},
        "proxies":{"proxies":{
          "GLOBAL":{"type":"Selector","now":"a","all":["a","A","Missing"]},
          "a":{"type":"Selector","now":"DIRECT","all":["DIRECT"]},
          "A":{"type":"VLESS"}
        }}
      }
      """
    )
    XCTAssertFalse(snapshot.globalRoutesThroughProxy)
    XCTAssertEqual(snapshot.globalProxyTarget, "A")
    XCTAssertFalse(snapshot.selecting(group: "a", proxy: "DIRECT")!.globalRoutesThroughProxy)

    var missing = snapshot
    missing.proxies.proxies["GLOBAL"]?.now = "Missing"
    missing.proxies.proxies["GLOBAL"]?.all = ["Missing"]
    XCTAssertFalse(missing.globalRoutesThroughProxy)
    XCTAssertNil(missing.globalProxyTarget)
  }

  func testDashboardLogRedactionRemovesCredentialsBeforeUIRetention() {
    let redacted = DashboardLogRedaction.redact(
      "GET https://user:pass@example.com/sub?token=abc password=hunter2 "
        + "Authorization: Bearer short-secret auth=Basic dXNlcjpwYXNz "
        + "Cookie: session=short-cookie https://only-token@example.com/sub/path-secret "
        + String(repeating: "a", count: 48)
    )

    XCTAssertFalse(redacted.contains("user:pass"))
    XCTAssertFalse(redacted.contains("token=abc"))
    XCTAssertFalse(redacted.contains("hunter2"))
    XCTAssertFalse(redacted.contains("short-secret"))
    XCTAssertFalse(redacted.contains("dXNlcjpwYXNz"))
    XCTAssertFalse(redacted.contains("short-cookie"))
    XCTAssertFalse(redacted.contains("only-token"))
    XCTAssertFalse(redacted.contains("path-secret"))
    XCTAssertFalse(redacted.contains(String(repeating: "a", count: 48)))
    XCTAssertTrue(redacted.contains("<redacted>"))
  }

  @MainActor
  func testPreviewFixturesAreLimitedToCheckoutBuildProducts() {
    let enabled = ["MIHOMO_NATIVE_UI_PREVIEW": "1"]
    XCTAssertTrue(
      DashboardStore.previewRequested(
        environment: enabled, arguments: [],
        executableURL: URL(
          fileURLWithPath: "/work/mihomo-app/build/MihomoBox.app/Contents/MacOS/mihomo-app"
        ),
        developmentUpdatesDisabled: true
      ))
    XCTAssertTrue(
      DashboardStore.previewRequested(
        environment: [:], arguments: ["--native-ui-preview"],
        executableURL: URL(fileURLWithPath: "/work/mihomo-app/.build/debug/preview")
      ))
    XCTAssertFalse(
      DashboardStore.previewRequested(
        environment: enabled, arguments: [],
        executableURL: URL(fileURLWithPath: "/Applications/MihomoBox.app/Contents/MacOS/mihomo-app"),
        developmentUpdatesDisabled: false
      ))
    XCTAssertFalse(
      DashboardStore.previewRequested(
        environment: [:],
        executableURL: URL(fileURLWithPath: "/work/mihomo-app/.build/debug/preview")
      ))
    XCTAssertFalse(
      DashboardStore.previewRequested(
        environment: enabled, arguments: [],
        executableURL: URL(
          fileURLWithPath: "/Applications/.build/MihomoBox.app/Contents/MacOS/mihomo-app"
        ),
        developmentUpdatesDisabled: false
      ))
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try decoder.decode(type, from: Data(json.utf8))
  }
}
