import XCTest
@testable import MihomoControl

final class SigningCertificateRequirementTests: XCTestCase {
  private let publishedLeaf = "2E1EF531C972A15F5B5C58855001FA6FA1186383"
  private let cloudLeaf = "44B2EB8C6C3C6A85A3687EEDED7D85EB7C13524A"

  func testPublishedLeafIncludesCloudLeafExactlyOnce() throws {
    let requirement = try SigningCertificateRequirement.certificateFamilyRequirement(
      currentLeafSHA1: publishedLeaf.lowercased()
    )

    XCTAssertEqual(
      requirement,
      "anchor apple generic and (certificate leaf = H\"\(publishedLeaf)\" or " +
        "certificate leaf = H\"\(cloudLeaf)\")"
    )
  }

  func testCloudLeafIncludesPublishedLeafExactlyOnce() throws {
    let requirement = try SigningCertificateRequirement.certificateFamilyRequirement(
      currentLeafSHA1: cloudLeaf
    )

    XCTAssertEqual(
      requirement,
      "anchor apple generic and (certificate leaf = H\"\(publishedLeaf)\" or " +
        "certificate leaf = H\"\(cloudLeaf)\")"
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
