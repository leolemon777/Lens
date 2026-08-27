import XCTest
@testable import LensMac

final class WindowSourceLossDetectorTests: XCTestCase {
    func testRequiresTwoConsecutiveMissingSnapshots() {
        var detector = WindowSourceLossDetector()

        XCTAssertFalse(detector.record(isAvailable: false))
        XCTAssertTrue(detector.record(isAvailable: false))
    }

    func testAvailableSnapshotResetsTransientMiss() {
        var detector = WindowSourceLossDetector()

        XCTAssertFalse(detector.record(isAvailable: false))
        XCTAssertFalse(detector.record(isAvailable: true))
        XCTAssertEqual(detector.consecutiveMisses, 0)
        XCTAssertFalse(detector.record(isAvailable: false))
    }

    func testThresholdIsNeverZero() {
        var detector = WindowSourceLossDetector(requiredConsecutiveMisses: 0)

        XCTAssertTrue(detector.record(isAvailable: false))
    }
}
