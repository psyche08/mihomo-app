import XCTest
@testable import MihomoControl

final class SigningCertificateRequirementTests: XCTestCase {
  private let publishedLeaf = "2E1EF531C972A15F5B5C58855001FA6FA1186383"

  func testPublishedLeafDoesNotDuplicateMigrationClause() throws {
    let requirement = try SigningCertificateRequirement.certificateFamilyRequirement(
      currentLeafSHA1: publishedLeaf.lowercased()
    )

    XCTAssertEqual(
      requirement,
      "anchor apple generic and certificate leaf = H\"\(publishedLeaf)\""
    )
  }

  func testCloudLeafIsCombinedWithPublishedLeafExactly() throws {
    let cloudLeaf = "0123456789ABCDEF0123456789ABCDEF01234567"
    let requirement = try SigningCertificateRequirement.certificateFamilyRequirement(
      currentLeafSHA1: cloudLeaf
    )

    XCTAssertEqual(
      requirement,
      "anchor apple generic and (certificate leaf = H\"\(cloudLeaf)\" or " +
        "certificate leaf = H\"\(publishedLeaf)\")"
    )
  }

  func testMalformedLeafFailsClosed() {
    XCTAssertThrowsError(
      try SigningCertificateRequirement.certificateFamilyRequirement(
        currentLeafSHA1: "not-a-certificate"
      )
    )
  }
}
