import XCTest
@testable import MihomoBoxApp

final class AppProxyCommandTests: XCTestCase {
    @MainActor func testParsesOnlyTheSupportedActions() throws {
        func parse(_ words: String) throws -> AppProxyCommand.Invocation {
            try AppProxyCommand.parse(words.split(separator: " ").map(String.init))
        }
        XCTAssertEqual(try parse("--app-proxy status"), .init(action: "status", application: nil, approve: false))
        XCTAssertEqual(try parse("--app-proxy targets chatgpt"), .init(action: "targets", application: "chatgpt", approve: false))
        XCTAssertEqual(try parse("--app-proxy enable chatgpt"), .init(action: "enable", application: "chatgpt", approve: false))
        XCTAssertEqual(try parse("--app-proxy enable chatgpt --approve"), .init(action: "enable", application: "chatgpt", approve: true))
        XCTAssertEqual(try parse("--app-proxy disable claude"), .init(action: "disable", application: "claude", approve: false))
        XCTAssertEqual(try parse("--app-proxy on").action, "on")
        XCTAssertEqual(try parse("--app-proxy off").action, "off")
        for invalid in ["--app-proxy", "--app-proxy status extra", "--app-proxy enable", "--app-proxy enable a --yes",
                        "--app-proxy enable a --approve b", "--app-proxy disable a --approve", "--app-proxy targets",
                        "--app-proxy remove a", "status --app-proxy"] {
            XCTAssertThrowsError(try parse(invalid), invalid)
        }
    }
}
