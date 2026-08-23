import XCTest

@testable import MihomoDNSCore

final class MonotonicStartupClockTests: XCTestCase {
    func testElapsedMillisecondsUsesMonotonicNanoseconds() {
        XCTAssertEqual(
            MonotonicStartupClock.elapsedMilliseconds(
                startedAtNanoseconds: 1_000_000,
                nowNanoseconds: 3_999_999
            ),
            2
        )
        XCTAssertEqual(
            MonotonicStartupClock.elapsedMilliseconds(
                startedAtNanoseconds: 2,
                nowNanoseconds: 1
            ),
            0
        )
    }
}
