import Foundation
import MihomoControl
import XCTest

final class ControlProtocolTests: XCTestCase {
    func testComponentUpdatePackageBinaryRoundTrip() throws {
        let package = ComponentUpdatePackage(
            appVersion: "0.4.0",
            components: [
                ManagedComponent.daemon.rawValue: Data([0, 1, 2]),
                ManagedComponent.agent.rawValue: Data([3, 4]),
                ManagedComponent.mihomo.rawValue: Data([5, 6, 7, 8]),
            ]
        )

        let decoded = try ComponentUpdatePackage.decode(package.encoded())
        XCTAssertEqual(decoded.formatVersion, ComponentUpdatePackage.currentFormatVersion)
        XCTAssertEqual(decoded.appVersion, "0.4.0")
        XCTAssertEqual(decoded.components, package.components)
    }

    func testComponentDigestIsStable() {
        XCTAssertEqual(
            ComponentUpdatePackage.digest(Data("MihomoBox".utf8)),
            "a6cf9ca5fc8c961aa8dfc56139625e8dd3dfe6f3d3df86c1db15db06b9c23194"
        )
    }

    func testControllerStreamOwnershipScopesNextAndCloseToOpeningPeer() {
        let peerAObject = NSObject()
        let peerBObject = NSObject()
        let peerA = ObjectIdentifier(peerAObject)
        let peerB = ObjectIdentifier(peerBObject)
        var ownership = ControllerStreamOwnership()

        XCTAssertTrue(ownership.register(identifier: "stream", owner: peerA))
        XCTAssertTrue(
            ownership.allows(identifier: "stream", owner: peerA),
            "the opening peer may request the next message"
        )
        XCTAssertFalse(
            ownership.allows(identifier: "stream", owner: peerB),
            "a different peer may not request the next message"
        )
        XCTAssertFalse(
            ownership.remove(identifier: "stream", owner: peerB),
            "a different peer may not close the stream"
        )
        XCTAssertTrue(
            ownership.allows(identifier: "stream", owner: peerA),
            "a rejected close must leave the opening peer's stream intact"
        )
        XCTAssertTrue(ownership.remove(identifier: "stream", owner: peerA))
        XCTAssertFalse(
            ownership.allows(identifier: "stream", owner: peerA),
            "an accepted close must delete the ownership record"
        )
    }

    func testControllerStreamOwnershipCleanupDeletesExpiredAndPeerOwnedRecords() {
        let peerAObject = NSObject()
        let peerBObject = NSObject()
        let peerA = ObjectIdentifier(peerAObject)
        let peerB = ObjectIdentifier(peerBObject)
        var ownership = ControllerStreamOwnership()

        XCTAssertTrue(ownership.register(identifier: "expired", owner: peerA))
        XCTAssertTrue(ownership.remove(identifier: "expired"))
        XCTAssertFalse(ownership.allows(identifier: "expired", owner: peerA))

        XCTAssertTrue(ownership.register(identifier: "a-1", owner: peerA))
        XCTAssertTrue(ownership.register(identifier: "a-2", owner: peerA))
        XCTAssertTrue(ownership.register(identifier: "b-1", owner: peerB))
        XCTAssertEqual(Set(ownership.removeAll(ownedBy: peerA)), Set(["a-1", "a-2"]))
        XCTAssertFalse(ownership.allows(identifier: "a-1", owner: peerA))
        XCTAssertFalse(ownership.allows(identifier: "a-2", owner: peerA))
        XCTAssertTrue(ownership.allows(identifier: "b-1", owner: peerB))
    }

    func testControllerStreamOwnershipKeepsOwnerlessInternalCompatibility() {
        let peerObject = NSObject()
        let peer = ObjectIdentifier(peerObject)
        var ownership = ControllerStreamOwnership()

        XCTAssertTrue(ownership.register(identifier: "internal", owner: nil))
        XCTAssertTrue(ownership.allows(identifier: "internal", owner: nil))
        XCTAssertFalse(ownership.allows(identifier: "internal", owner: peer))
        XCTAssertTrue(ownership.remove(identifier: "internal", owner: nil))
        XCTAssertFalse(ownership.allows(identifier: "internal", owner: nil))
    }
}

extension ControlProtocolTests {
    func testRemovedWebDashboardRoutesStayRefused() {
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/dns/query"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/configs"))
    }

    func testUpgradeAndUnknownPathsStayRefused() {
        // These keep the WebView from replacing managed binaries or the UI.
        // The bridge answers them 403 before they get here; this is the layer
        // behind it, and it must refuse them on its own.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade/ui"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/upgrade/core"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "POST", path: "/restart"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/anything-else"))
        // A path that merely starts with an allowed one is not allowed.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/dns/query/extra"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/configs/extra"))
    }

    func testParameterisedRoutesAcceptOneSegmentOnly() {
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/Node"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "DELETE", path: "/proxies/Node"))
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "GET", path: "/proxies/Node/delay"))
        XCTAssertTrue(ControllerRequestPolicy.allows(method: "DELETE", path: "/connections/abc"))
        // An empty or multi-segment name must not slip through.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/proxies/a/b"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/proxies//delay"))
        // Methods are per-route, not global.
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "GET", path: "/proxies/Node"))
        XCTAssertFalse(ControllerRequestPolicy.allows(method: "PUT", path: "/connections/abc"))
    }

    func testParameterisedRoutesPreserveEncodedNamesAsOneSafeSegment() {
        XCTAssertTrue(ControllerRequestPolicy.allows(
            method: "GET",
            path: "/proxies/a%2Fb/delay"
        ))
        XCTAssertTrue(ControllerRequestPolicy.allows(
            method: "PUT",
            path: "/providers/rules/%E6%97%A5%E6%9C%AC"
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "PUT", path: "/providers/proxies/%E6%97%A5%E6%9C%AC"
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "DELETE",
            path: "/proxies/%2E%2E"
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "DELETE",
            path: "/proxies/%2e"
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "DELETE",
            path: "/proxies/Node..01"
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET",
            path: "/proxies/%00/delay"
        ))
    }

    func testCompleteRequestPinsDelayProbeAndTimeout() {
        var valid = URLComponents()
        valid.percentEncodedPath = "/proxies/a%2Fb/delay"
        valid.queryItems = [
            URLQueryItem(name: "timeout", value: "5000"),
            URLQueryItem(name: "url", value: ControllerRequestPolicy.latencyProbe),
        ]
        XCTAssertTrue(ControllerRequestPolicy.allows(
            method: "GET", target: try XCTUnwrap(valid.string), body: nil
        ))
        valid.percentEncodedPath = "/providers/proxies/Provider/Node/healthcheck"
        XCTAssertTrue(ControllerRequestPolicy.allows(
            method: "GET", target: try XCTUnwrap(valid.string), body: nil
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET",
            target: "/providers/proxies/Provider/healthcheck?timeout=5000&url=https://cp.cloudflare.com/generate_204",
            body: nil
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET", target: "/proxies/Node/delay", body: nil
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET",
            target: "/proxies/Node/delay?timeout=5000&url=http://127.0.0.1:8080/",
            body: nil
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET",
            target: "/proxies/Node/delay?timeout=0&url=https://cp.cloudflare.com/generate_204",
            body: nil
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET", target: "/configs?secret=1", body: nil
        ))
    }

    func testCompleteRequestAllowsOnlyTypedRuntimeConfigPatches() throws {
        let allowed: [[String: Any]] = [
            ["allow-lan": true],
            ["ipv6": false],
            ["log-level": "silent"],
            ["log-level": "warning"],
            ["unified-delay": true],
            ["tcp-concurrent": false],
            ["find-process-mode": "strict"],
        ]
        for object in allowed {
            XCTAssertTrue(ControllerRequestPolicy.allows(
                method: "PATCH", target: "/configs", body: try json(object)
            ))
        }

        let refused: [[String: Any]] = [
            ["tun": ["enable": false]],
            ["dns": ["enable": false]],
            ["external-controller": "0.0.0.0:9090"],
            ["secret": "replacement"],
            ["allow-lan": true, "ipv6": false],
            ["allow-lan": 1],
            ["log-level": "trace"],
            ["find-process-mode": "unknown"],
            ["mode": "direct"],
        ]
        for object in refused {
            XCTAssertFalse(ControllerRequestPolicy.allows(
                method: "PATCH", target: "/configs", body: try json(object)
            ))
        }
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "PUT",
            target: "/configs",
            body: try json(["path": "", "payload": "tun:\n  enable: false\n"])
        ))
    }

    func testCompleteRequestValidatesMutationBodies() throws {
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "PUT", target: "/proxies/Auto", body: try json(["name": "Node A"])
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "PUT", target: "/proxies/Auto", body: try json(["name": ""])
        ))
        XCTAssertTrue(ControllerRequestPolicy.allows(
            method: "PATCH", target: "/rules/disable", body: try json(["12": true])
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "PATCH", target: "/rules/disable", body: try json(["-1": true])
        ))
        XCTAssertFalse(ControllerRequestPolicy.allows(
            method: "GET", target: "/version", body: Data("{}".utf8)
        ))
    }

    /// A self-replacing daemon drops the connection instead of replying, and
    /// that must read as "it went away", not "it refused" — otherwise a
    /// successful component upgrade reports itself as a failure.
    func testDisconnectionIsDistinguishedFromRefusal() {
        XCTAssertTrue(ControlError.connectionFailed.isDisconnection)
        XCTAssertTrue(ControlError.invalidReply.isDisconnection)

        XCTAssertFalse(ControlError.rejected("Mihomo agent is not running").isDisconnection)
        XCTAssertFalse(ControlError.unsignedProcess.isDisconnection)
        XCTAssertFalse(ControlError.invalidSigningInformation.isDisconnection)
        XCTAssertFalse(ControlError.invalidRequirement.isDisconnection)
        XCTAssertFalse(ControlError.invalidComponentSignature.isDisconnection)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

extension ControlProtocolTests {
    func testDaemonRouteSnapshotFindsSafeGlobalTargetsAndRejectsUnsafeSelections() throws {
        let snapshot = try ControllerRouteSnapshot(
            configsData: Data(#"{"mode":"global"}"#.utf8),
            proxiesData: Data(#"""
            {"proxies":{
              "GLOBAL":{"name":"GLOBAL","now":"DIRECT","all":["DIRECT","Auto","A"]},
              "Auto":{"name":"Auto","now":"Node","all":["Node","DIRECT"]},
              "Node":{"name":"Node","type":"VLESS"},
              "A":{"name":"A","type":"VLESS"},
              "DIRECT":{"name":"DIRECT","type":"Direct"}
            }}
            """#.utf8)
        )

        XCTAssertFalse(snapshot.globalRoutesThroughProxy)
        XCTAssertEqual(snapshot.globalProxyTarget, "Auto")
        let throughAuto = try XCTUnwrap(snapshot.selecting(group: "GLOBAL", proxy: "Auto"))
        XCTAssertTrue(throughAuto.globalRoutesThroughProxy)
        let throughNode = try XCTUnwrap(throughAuto.selecting(group: "Auto", proxy: "Node"))
        XCTAssertTrue(throughNode.globalRoutesThroughProxy)
        XCTAssertFalse(
            throughAuto.selecting(group: "Auto", proxy: "DIRECT")!.globalRoutesThroughProxy
        )
        XCTAssertNil(snapshot.selecting(group: "Auto", proxy: "Missing"))
    }

    func testDaemonRouteSnapshotIsCaseSensitiveAndMissingTargetsFailClosed() throws {
        let snapshot = ControllerRouteSnapshot(mode: "global", proxies: [
            "GLOBAL": .init(name: "GLOBAL", now: "a", all: ["a", "A", "Missing"]),
            "a": .init(name: "a", type: "Selector", now: "DIRECT", all: ["DIRECT"]),
            "A": .init(name: "A", type: "VLESS"),
        ])

        XCTAssertFalse(snapshot.globalRoutesThroughProxy)
        XCTAssertEqual(snapshot.globalProxyTarget, "A")
        XCTAssertNil(snapshot.selecting(group: "a", proxy: "Missing"))
    }

    func testDaemonRouteSnapshotRejectsRenamedBuiltinsUnknownLeavesAndWrongGlobalCase() {
        for type in ["Direct", "Reject", "Compatible", "Pass", ""] {
            let snapshot = ControllerRouteSnapshot(mode: "global", proxies: [
                "GLOBAL": .init(
                    name: "GLOBAL", type: "Selector", now: "Friendly", all: ["Friendly"]
                ),
                "Friendly": .init(name: "Friendly", type: type),
            ])
            XCTAssertFalse(snapshot.globalRoutesThroughProxy, "type=\(type)")
            XCTAssertNil(snapshot.globalProxyTarget, "type=\(type)")
        }

        let wrongCase = ControllerRouteSnapshot(mode: "global", proxies: [
            "global": .init(name: "global", type: "Selector", now: "Node", all: ["Node"]),
            "Node": .init(name: "Node", type: "VLESS"),
        ])
        XCTAssertFalse(wrongCase.globalRoutesThroughProxy)
        XCTAssertNil(wrongCase.globalProxyTarget)
    }
}
