import Foundation
import MihomoDNSCore
import XCTest

final class StoredProfileDeletionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["active.yaml", "spare.yaml"] {
            try Data("mode: rule\n".utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testDeletesAnInactiveProfileOnly() throws {
        try StoredProfileDeletion.delete(name: "spare.yaml", in: directory, activeProfile: "active.yaml")
        XCTAssertEqual(try names(), ["active.yaml"])
    }

    func testRefusesTheActiveProfileInAnyCase() throws {
        for name in ["active.yaml", "ACTIVE.yaml"] {
            XCTAssertThrowsError(
                try StoredProfileDeletion.delete(name: name, in: directory, activeProfile: "active.yaml")
            ) { XCTAssertEqual($0 as? StoredProfileDeletion.Failure, .active, name) }
        }
        XCTAssertEqual(try names(), ["active.yaml", "spare.yaml"])
    }

    func testRequiresAnExactlyNamedEntry() throws {
        // On a case-insensitive volume "Spare.yaml" would open spare.yaml.
        for name in ["missing.yaml", "Spare.yaml"] {
            XCTAssertThrowsError(
                try StoredProfileDeletion.delete(name: name, in: directory, activeProfile: "active.yaml")
            ) { XCTAssertEqual($0 as? StoredProfileDeletion.Failure, .missing, name) }
        }
        XCTAssertEqual(try names(), ["active.yaml", "spare.yaml"])
    }

    func testRefusesLinksAndDirectories() throws {
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("profile-deletion-target-\(UUID().uuidString).yaml")
        try Data("keep\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.yaml"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder.yaml"),
            withIntermediateDirectories: false
        )
        for name in ["link.yaml", "folder.yaml"] {
            XCTAssertThrowsError(
                try StoredProfileDeletion.delete(name: name, in: directory, activeProfile: nil)
            ) { XCTAssertEqual($0 as? StoredProfileDeletion.Failure, .notRegularFile, name) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try names(), ["active.yaml", "folder.yaml", "link.yaml", "spare.yaml"])
    }

    func testDeletesWithoutAnActiveProfile() throws {
        try StoredProfileDeletion.delete(name: "active.yaml", in: directory, activeProfile: nil)
        XCTAssertEqual(try names(), ["spare.yaml"])
    }
}
