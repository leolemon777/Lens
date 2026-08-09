import XCTest
@testable import ScreenTraceCore

final class AutoCameraPlannerTests: XCTestCase {
    func testNoClicksKeepsOverviewOnly() {
        let result = AutoCameraPlanner().plan(clicks: [], duration: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].reason, .baseline)
        XCTAssertEqual(result[0].scale, 1)
    }

    func testClickCreatesFocusHoldAndReturn() {
        let click = makeClick(time: 1, x: 0.5, y: 0.5)
        let result = AutoCameraPlanner().plan(clicks: [click], duration: 4)

        XCTAssertEqual(result.map(\.reason), [.baseline, .clickFocus, .clickHold, .returnToOverview])
        XCTAssertGreaterThan(result[1].scale, 1)
        XCTAssertEqual(result.last?.scale, 1)
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    func testEdgeClickIsClampedInsideVisibleViewport() {
        let planner = AutoCameraPlanner(configuration: .init(focusScale: 2))
        let result = planner.plan(clicks: [makeClick(time: 1, x: 0, y: 1)], duration: 4)
        let focus = result.first { $0.reason == .clickFocus }!

        XCTAssertEqual(focus.center.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(focus.center.y, 0.75, accuracy: 0.0001)
    }

    func testRapidClicksRetargetWithoutReturningToOverviewBetweenThem() {
        let clicks = [
            makeClick(time: 1, x: 0.3, y: 0.4),
            makeClick(time: 1.6, x: 0.7, y: 0.6)
        ]
        let result = AutoCameraPlanner().plan(clicks: clicks, duration: 5)
        let firstFocusIndex = result.firstIndex { $0.reason == .clickFocus }!
        let secondFocusIndex = result[(firstFocusIndex + 1)...].firstIndex { $0.reason == .clickFocus }!
        XCTAssertFalse(result[(firstFocusIndex + 1)..<secondFocusIndex].contains {
            $0.reason == .returnToOverview
        })
    }

    func testMouseUpAndClicksOutsideCaptureAreIgnored() {
        let withoutNormalized = ClickEvent(
            time: 1,
            button: .left,
            phase: .down,
            location: TracePoint(x: 100, y: 100),
            clickCount: 1
        )
        let mouseUp = ClickEvent(
            time: 2,
            button: .left,
            phase: .up,
            location: TracePoint(x: 100, y: 100),
            normalizedLocation: TracePoint(x: 0.5, y: 0.5),
            clickCount: 1
        )
        XCTAssertEqual(
            AutoCameraPlanner().plan(clicks: [withoutNormalized, mouseUp], duration: 4).count,
            1
        )
    }

    private func makeClick(time: Double, x: Double, y: Double) -> ClickEvent {
        ClickEvent(
            time: time,
            button: .left,
            phase: .down,
            location: TracePoint(x: x * 1000, y: y * 1000),
            normalizedLocation: TracePoint(x: x, y: y),
            displayID: 1,
            clickCount: 1
        )
    }
}
