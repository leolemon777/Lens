import Foundation
import XCTest
@testable import LensCore

final class ScrollingCapturePlanTests: XCTestCase {
    func testPlanRoundTripsFramePlacementsAndClampsUnsafeMetrics() throws {
        let frame = ScrollingCaptureFrame(
            index: -1,
            relativePath: "raw/scrolling/frame-000.png",
            verticalOffsetPixels: -20,
            appendedHeightPixels: -4,
            overlapDifference: 2
        )
        XCTAssertEqual(frame.index, 0)
        XCTAssertEqual(frame.verticalOffsetPixels, 0)
        XCTAssertEqual(frame.appendedHeightPixels, 0)
        XCTAssertEqual(frame.overlapDifference, 1)

        let plan = ScrollingCapturePlan(
            displayID: 9,
            sourceRect: LensRect(x: 12, y: 34, width: 500, height: 600),
            viewportDimensions: LensDimensions(width: 1_000, height: 1_200),
            outputDimensions: LensDimensions(width: 1_000, height: 4_800),
            frames: [frame]
        )
        let decoded = try JSONDecoder().decode(
            ScrollingCapturePlan.self,
            from: JSONEncoder().encode(plan)
        )

        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.schemaVersion, ScrollingCapturePlan.currentSchemaVersion)
    }
}
