import Foundation
import XCTest
@testable import MihomoDNSCore

final class HealthSnapshotChangesTests: XCTestCase {
    func testNotificationsSurviveAtomicFileReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("runtime-health.json")
        let changes = try XCTUnwrap(HealthSnapshotChanges(path: file.path))
        XCTAssertFalse(changes.wait(timeout: 0.02))
        for generation in 0..<6 {
            while changes.wait(timeout: 0) {}
            let data = Data("generation-\(generation)".utf8)
            try data.write(to: file, options: .atomic)
            XCTAssertTrue(changes.wait(timeout: 2), "replacement must wake the waiting transaction")
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testUnavailableDirectoryAllowsPollingFallback() {
        XCTAssertNil(HealthSnapshotChanges(path: "/private/tmp/\(UUID().uuidString)/runtime-health.json"))
    }
}
