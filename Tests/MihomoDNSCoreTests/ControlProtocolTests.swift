import Foundation
import MihomoControl
import XCTest

final class ControlProtocolTests: XCTestCase {
    func testRoutineAuditSuppressesOnlyHighFrequencySuccessfulReads() {
        XCTAssertFalse(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .trayState))
        XCTAssertFalse(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .controllerStreamNext))
        XCTAssertTrue(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .status))
        XCTAssertTrue(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .setTUN))
        XCTAssertTrue(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .reloadProfile))
        XCTAssertTrue(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .localDoHStatus))
        XCTAssertTrue(ControlRequestAuditPolicy.logsRoutineLifecycle(for: .installLocalDoH))
    }

    func testLocalDoHStatusRoundTripsWithoutProfileDetails() throws {
        let status = LocalDoHStatus(
            serverPrepared: true,
            profileInstalled: true,
            profileInspectionSucceeded: true,
            runtimeHealthy: true,
            systemDNSManaged: false,
            installedDomainCount: 2,
            preparedDomainCount: 5_123
        )

        let decoded = try JSONDecoder().decode(
            LocalDoHStatus.self,
            from: JSONEncoder().encode(status)
        )

        XCTAssertEqual(decoded, status)
    }

    func testLocalDoHStatusDefaultsPreparedCountForOlderResponses() throws {
        let data = Data(
            """
            {
              "server_prepared": false,
              "profile_installed": false,
              "profile_inspection_succeeded": true,
              "runtime_healthy": false,
              "installed_domain_count": 0
            }
            """.utf8
        )

        XCTAssertEqual(
            try JSONDecoder().decode(LocalDoHStatus.self, from: data).preparedDomainCount,
            0
        )
    }

    func testLocalDoHPlanSummaryRoundTripsWithoutExpandedDomains() throws {
        let summary = LocalDoHPlanSummary(
            domainCount: 5_123,
            omittedRuleCount: 2,
            exactDomainApproximationCount: 3,
            expandedGeoSiteRuleCount: 7,
            unrepresentableGeoSiteEntryCount: 11,
            invertedGeoSiteRuleCount: 1
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                LocalDoHPlanSummary.self,
                from: JSONEncoder().encode(summary)
            ),
            summary
        )
    }

    func testFallbackStatusAndStaleProfilePresence() throws {
        let status = LocalDoHStatus(
            serverPrepared: true, profileInstalled: false,
            profileInspectionSucceeded: true, runtimeHealthy: false,
            systemDNSManaged: true, globalDNSFallback: true,
            fallbackProfileRemovalRequired: true
        )
        XCTAssertEqual(status, try JSONDecoder().decode(
            LocalDoHStatus.self, from: JSONEncoder().encode(status)
        ))
        let stale: [String: Any] = [
            "PayloadIdentifier": LocalDoHStatus.profileIdentifier,
            "PayloadContent": [["DNSSettings": [
                "ServerURL": "https://127.0.0.1:9443/dns-query",
                "SupplementalMatchDomains": ["example.com"],
            ]]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: stale, format: .xml, options: 0)
        XCTAssertEqual(LocalDoHProfileInspection.presence(in: data), true)
        XCTAssertNil(LocalDoHProfileDocument.validatedDomainCount(in: data))
        XCTAssertEqual(LocalDoHProfileInspection.presence(in: Data(
            "There are no configuration profiles installed in the system domain".utf8
        )), false)
        XCTAssertNil(LocalDoHProfileInspection.presence(in: Data("unexpected output".utf8)))
    }

    func testPreparedLocalDoHProfileRejectsAlteredPrivilegedFields() throws {
        let rootCertificate = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        let valid = try LocalDoHProfileDocument.data(
            for: LocalDoHDomainPlan(domains: ["example.com", "claude.ai"]),
            rootCertificate: rootCertificate
        )
        XCTAssertEqual(
            LocalDoHProfileDocument.validatedDomainCount(
                in: valid,
                expectedRootCertificate: rootCertificate
            ),
            2
        )

        var object = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: valid,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        var content = try XCTUnwrap(object["PayloadContent"] as? [[String: Any]])
        let dnsIndex = try XCTUnwrap(content.firstIndex(where: {
            $0["PayloadType"] as? String == "com.apple.dnsSettings.managed"
        }))
        var settings = try XCTUnwrap(content[dnsIndex]["DNSSettings"] as? [String: Any])
        settings["ServerURL"] = "https://example.invalid/dns-query"
        content[dnsIndex]["DNSSettings"] = settings
        object["PayloadContent"] = content
        let altered = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        XCTAssertNil(LocalDoHProfileDocument.validatedDomainCount(in: altered))
        XCTAssertNil(
            LocalDoHProfileDocument.validatedDomainCount(
                in: valid,
                expectedRootCertificate: Data([0x01])
            )
        )
    }

    func testLocalDoHProfileInspectionReturnsOnlyFixedProfileStateAndCount() throws {
        let profile: [String: Any] = [
            "_computerlevel": [[
                "PayloadIdentifier": LocalDoHStatus.profileIdentifier,
                "PayloadContent": [[
                    "DNSSettings": [
                        "SupplementalMatchDomains": ["example.com", "claude.ai"],
                    ],
                ]],
            ]],
            "unrelated": [[
                "PayloadIdentifier": "com.example.other",
                "PayloadContent": [[
                    "DNSSettings": [
                        "SupplementalMatchDomains": ["private.example"],
                    ],
                ]],
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: profile,
            format: .xml,
            options: 0
        )

        XCTAssertEqual(
            LocalDoHProfileInspection.inspect(propertyList: data),
            LocalDoHProfileInspection(installed: true, domainCount: 2)
        )
        XCTAssertNil(LocalDoHProfileInspection.inspect(propertyList: Data("not a plist".utf8)))
    }

    func testInstalledLocalDoHProfileMustMatchCurrentRootCertificate() throws {
        let plan = LocalDoHDomainPlan(
            domains: ["example.com"],
            omittedRules: 0,
            exactDomainApproximations: 0,
            expandedGeoSiteRules: 0,
            unrepresentableGeoSiteEntries: 0,
            invertedGeoSiteRules: 0
        )
        let currentRoot = Data([0x01, 0x02, 0x03])
        let document = try LocalDoHProfileDocument.data(
            for: plan,
            rootCertificate: currentRoot
        )
        let installed: [String: Any] = [
            "_computerlevel": [
                try XCTUnwrap(
                    PropertyListSerialization.propertyList(
                        from: document,
                        options: [],
                        format: nil
                    ) as? [String: Any]
                )
            ]
        ]
        let output = try PropertyListSerialization.data(
            fromPropertyList: installed,
            format: .xml,
            options: 0
        )

        XCTAssertEqual(
            LocalDoHProfileInspection.validatedInstalled(
                propertyList: output,
                expectedRootCertificate: currentRoot
            ),
            LocalDoHProfileInspection(installed: true, domainCount: 1)
        )
        XCTAssertNil(
            LocalDoHProfileInspection.validatedInstalled(
                propertyList: output,
                expectedRootCertificate: Data([0xff])
            )
        )
    }

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

    func testInstalledProfileReportWithRedactedCertificateMatchesPreparedDocument() throws {
        let certificate = Data([1, 2, 3])
        let prepared = try LocalDoHProfileDocument.data(
            for: LocalDoHDomainPlan(domains: ["example.com", "example.org"]),
            rootCertificate: certificate
        )
        let original = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: prepared, format: nil
        ) as? [String: Any])
        let content = try XCTUnwrap(original["PayloadContent"] as? [[String: Any]])
        let items = content.map { item -> [String: Any] in
            var result = item
            result.removeValue(forKey: "PayloadCertificateFileName")
            if let settings = result.removeValue(forKey: "DNSSettings") {
                result["PayloadContent"] = ["DNSSettings": settings]
            } else {
                result["PayloadContent"] = [String: Any]()
            }
            return result
        }
        var report: [String: Any] = [
            "ProfileIdentifier": LocalDoHStatus.profileIdentifier,
            "ProfileType": "Configuration", "ProfileVersion": 1,
            "ProfileUUID": original["PayloadUUID"]!, "ProfileItems": items,
        ]
        func validate(_ report: [String: Any], root: Data = certificate,
                      document: Data? = prepared) throws -> LocalDoHProfileInspection? {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["_computerlevel": [report]], format: .xml, options: 0
            )
            return LocalDoHProfileInspection.validatedInstalled(
                propertyList: data, expectedRootCertificate: root,
                expectedPreparedProfile: document
            )
        }
        XCTAssertEqual(try validate(report), .init(installed: true, domainCount: 2))
        XCTAssertNil(try validate(report, document: nil))
        XCTAssertNil(try validate(report, root: Data([9])))
        let good = report
        for field in ["ProfileUUID", "ProfileType", "ProfileVersion"] {
            report = good
            report[field] = "wrong"
            XCTAssertNil(try validate(report), field)
        }
        for field in ["PayloadType", "PayloadIdentifier", "PayloadUUID", "PayloadVersion"] {
            report = good
            var altered = items
            altered[0][field] = "wrong"
            report["ProfileItems"] = altered
            XCTAssertNil(try validate(report), field)
        }
        for (key, value) in [
            ("ServerURL", "https://127.0.0.1:9443/dns-query" as Any),
            ("ServerAddresses", ["198.18.0.1"] as Any),
            ("SupplementalMatchDomains", ["example.com"] as Any),
            ("DNSProtocol", "TLS" as Any),
        ] {
            report = good
            var altered = items
            var settings = content[1]["DNSSettings"] as! [String: Any]
            settings[key] = value
            altered[1]["PayloadContent"] = ["DNSSettings": settings]
            report["ProfileItems"] = altered
            XCTAssertNil(try validate(report), key)
        }
        report = good
        report["ProfileItems"] = [items[0], items[0]]
        XCTAssertNil(try validate(report))
        var disclosed = items
        disclosed[0]["PayloadContent"] = Data([9])
        report["ProfileItems"] = disclosed
        XCTAssertNil(try validate(report))
    }

    func testLocalDoHTrustFailureRecoveryRequiresContinuousObservedFailure() {
        var recovery = LocalDoHReadinessRecovery()
        XCTAssertFalse(recovery.needsFallback(profilePresent: true, ready: false, now: 0))
        XCTAssertFalse(recovery.needsFallback(profilePresent: true, ready: false, now: 59))
        XCTAssertTrue(recovery.needsFallback(profilePresent: true, ready: false, now: 60))
        XCTAssertFalse(recovery.needsFallback(profilePresent: true, ready: true, now: 61))
        XCTAssertFalse(recovery.needsFallback(profilePresent: true, ready: false, now: 62))
        XCTAssertFalse(recovery.needsFallback(profilePresent: nil, ready: false, now: 125))
        XCTAssertFalse(recovery.needsFallback(profilePresent: false, ready: false, now: 200))
        XCTAssertFalse(recovery.needsFallback(profilePresent: true, ready: false, now: 300))
        XCTAssertTrue(recovery.needsFallback(profilePresent: true, ready: false, now: 360))
    }

    func testLocalDoHMalformedIdentityNeverPassesSystemTrust() {
        XCTAssertFalse(LocalDoHTLSValidation.systemTrusts(serverPEM: Data(), rootDER: Data()))
        XCTAssertFalse(LocalDoHTLSValidation.systemTrusts(
            serverPEM: Data("-----BEGIN CERTIFICATE-----AQID-----END CERTIFICATE-----".utf8),
            rootDER: Data([1, 2, 3])
        ))
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

        XCTAssertFalse(
            ControlError.protocolVersionMismatch(expected: 2, received: 1).isDisconnection
        )
        XCTAssertFalse(ControlError.rejected("Mihomo agent is not running").isDisconnection)
        XCTAssertFalse(ControlError.unsignedProcess.isDisconnection)
        XCTAssertFalse(ControlError.invalidSigningInformation.isDisconnection)
        XCTAssertFalse(ControlError.invalidRequirement.isDisconnection)
        XCTAssertFalse(ControlError.invalidComponentSignature.isDisconnection)
    }

    func testControlResponseRecognisesOnlyExactLegacyDaemonProtocol() {
        var response = ControlResponse(success: false, error: "must not mask version mismatch")
        response.version = 1

        XCTAssertThrowsError(try response.validated()) { error in
            guard let controlError = error as? ControlError else {
                return XCTFail("expected ControlError, got \(error)")
            }
            guard case .protocolVersionMismatch(let expected, let received) = controlError else {
                return XCTFail("expected protocolVersionMismatch, got \(controlError)")
            }
            XCTAssertEqual(expected, mihomoControlProtocolVersion)
            XCTAssertEqual(received, 1)
            XCTAssertTrue(controlError.isLegacyDaemonProtocol)
            XCTAssertFalse(controlError.isDisconnection)
            XCTAssertTrue(controlError.localizedDescription.contains("Install / Repair Daemon"))
        }

        response.version = mihomoControlProtocolVersion + 1
        XCTAssertThrowsError(try response.validated()) { error in
            guard let controlError = error as? ControlError else {
                return XCTFail("expected ControlError, got \(error)")
            }
            guard case .protocolVersionMismatch(let expected, let received) = controlError else {
                return XCTFail("expected protocolVersionMismatch, got \(controlError)")
            }
            XCTAssertEqual(expected, mihomoControlProtocolVersion)
            XCTAssertEqual(received, mihomoControlProtocolVersion + 1)
            XCTAssertFalse(controlError.isLegacyDaemonProtocol)
            XCTAssertFalse(controlError.isDisconnection)
            XCTAssertTrue(controlError.localizedDescription.contains("update MihomoBox"))
        }
    }

    func testControlResponseRejectsNonpositiveProtocolAsInvalidReply() {
        var response = ControlResponse(success: false, error: "must not mask invalid version")
        response.version = 0

        XCTAssertThrowsError(try response.validated()) { error in
            guard let controlError = error as? ControlError,
                  case .invalidReply = controlError else {
                return XCTFail("expected invalidReply, got \(error)")
            }
        }
    }

    func testControlResponsePreservesSameVersionRejection() {
        let response = ControlResponse(success: false, error: "request refused")

        XCTAssertThrowsError(try response.validated()) { error in
            guard let controlError = error as? ControlError,
                  case let .rejected(message) = controlError else {
                return XCTFail("expected rejected, got \(error)")
            }
            XCTAssertEqual(message, "request refused")
        }
    }

    func testControlResponseReturnsSuccessfulResponseUnchanged() throws {
        let payload = Data([1, 2, 3])
        let response = ControlResponse(success: true, payload: payload)
        let validated = try response.validated()

        XCTAssertEqual(validated.version, response.version)
        XCTAssertEqual(validated.success, response.success)
        XCTAssertEqual(validated.payload, response.payload)
        XCTAssertEqual(validated.error, response.error)
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
