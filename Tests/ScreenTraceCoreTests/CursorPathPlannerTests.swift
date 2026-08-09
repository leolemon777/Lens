import XCTest
@testable import ScreenTraceCore

final class CursorPathPlannerTests: XCTestCase {
    func testEmptyAndOutOfCaptureEventsProduceNoPath() {
        let event = PointerEvent(
            time: 0,
            kind: .moved,
            location: TracePoint(x: 10, y: 20),
            displayID: 2
        )
        XCTAssertTrue(CursorPathPlanner().plan(events: []).isEmpty)
        XCTAssertTrue(CursorPathPlanner().plan(events: [event]).isEmpty)
    }

    func testSlowJitterIsSmoothed() {
        let rawX: [Double] = [0.50, 0.515, 0.49, 0.512, 0.495, 0.505]
        let events = rawX.enumerated().map { index, x in
            makeEvent(time: Double(index) / 60, x: x, y: 0.5)
        }
        let result = CursorPathPlanner().plan(events: events)
        let smoothedX = result.map(\.position.x)

        XCTAssertEqual(result.count, events.count)
        XCTAssertLessThan(range(smoothedX), range(rawX))
    }

    func testFastMovementUsesFasterResponse() {
        let planner = CursorPathPlanner()
        let result = planner.plan(events: [
            makeEvent(time: 0, x: 0.1, y: 0.5),
            makeEvent(time: 1.0 / 60.0, x: 0.9, y: 0.5)
        ])

        XCTAssertGreaterThan(result.last!.position.x, 0.5)
        XCTAssertLessThanOrEqual(result.last!.position.x, 0.9)
    }

    func testCoordinatesAreClampedAndTimesRemainSorted() {
        let result = CursorPathPlanner().plan(events: [
            makeEvent(time: 2, x: 2, y: -1),
            makeEvent(time: 1, x: 0.2, y: 0.3)
        ])
        XCTAssertEqual(result.map(\.time), [1, 2])
        XCTAssertTrue(result.allSatisfy {
            (0...1).contains($0.position.x) && (0...1).contains($0.position.y)
        })
    }

    private func makeEvent(time: Double, x: Double, y: Double) -> PointerEvent {
        PointerEvent(
            time: time,
            kind: .moved,
            location: TracePoint(x: x * 1000, y: y * 1000),
            normalizedLocation: TracePoint(x: x, y: y),
            displayID: 1
        )
    }

    private func range(_ values: [Double]) -> Double {
        (values.max() ?? 0) - (values.min() ?? 0)
    }
}
