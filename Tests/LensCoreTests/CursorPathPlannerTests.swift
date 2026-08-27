import XCTest
@testable import LensCore

final class CursorPathPlannerTests: XCTestCase {
    func testEmptyAndOutOfCaptureEventsProduceNoPath() {
        let event = PointerEvent(
            time: 0,
            kind: .moved,
            location: LensPoint(x: 10, y: 20),
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

    func testRawPlanKeepsOriginalNormalizedSamplesForZeroMillisecondRendering() {
        let events = [
            makeEvent(time: 0.1, x: 0.2, y: 0.8),
            makeEvent(time: 0.2, x: 0.9, y: 0.1)
        ]

        XCTAssertEqual(
            CursorPathPlanner().rawPlan(events: events),
            [
                AutoEditPlan.CursorKeyframe(
                    time: 0.1,
                    position: LensPoint(x: 0.2, y: 0.8),
                    kind: .moved
                ),
                AutoEditPlan.CursorKeyframe(
                    time: 0.2,
                    position: LensPoint(x: 0.9, y: 0.1),
                    kind: .moved
                )
            ]
        )
    }

    func testRawAndSmoothedPlansPreserveDragState() {
        let events = [
            PointerEvent(
                time: 0.1,
                kind: .moved,
                location: LensPoint(x: 100, y: 100),
                normalizedLocation: LensPoint(x: 0.1, y: 0.1),
                displayID: 1
            ),
            PointerEvent(
                time: 0.2,
                kind: .dragged,
                location: LensPoint(x: 300, y: 200),
                normalizedLocation: LensPoint(x: 0.3, y: 0.2),
                displayID: 1
            )
        ]

        XCTAssertEqual(CursorPathPlanner().rawPlan(events: events).last?.kind, .dragged)
        XCTAssertEqual(CursorPathPlanner().plan(events: events).last?.kind, .dragged)
    }

    func testScrollSamplesDoNotBecomeSyntheticCursorMovement() {
        let movement = makeEvent(time: 0.1, x: 0.2, y: 0.8)
        let scroll = PointerEvent(
            time: 0.2,
            kind: .scroll,
            location: LensPoint(x: 200, y: 800),
            normalizedLocation: LensPoint(x: 0.2, y: 0.8),
            displayID: 1,
            scrollDelta: LensPoint(x: 0, y: -12)
        )

        XCTAssertEqual(CursorPathPlanner().rawPlan(events: [movement, scroll]).count, 1)
        XCTAssertEqual(CursorPathPlanner().plan(events: [movement, scroll]).count, 1)
    }

    func testShapePlanCombinesPointerAndClickSamplesAndDeduplicatesChanges() {
        let pointer = PointerEvent(
            time: 0.2,
            kind: .moved,
            location: LensPoint(x: 100, y: 100),
            normalizedLocation: LensPoint(x: 0.1, y: 0.1),
            displayID: 1,
            cursorShape: .arrow
        )
        let repeatedClick = ClickEvent(
            time: 0.4,
            button: .left,
            phase: .down,
            location: LensPoint(x: 100, y: 100),
            clickCount: 1,
            cursorShape: .arrow
        )
        let handClick = ClickEvent(
            time: 0.8,
            button: .left,
            phase: .down,
            location: LensPoint(x: 400, y: 200),
            clickCount: 1,
            cursorShape: .pointingHand
        )

        XCTAssertEqual(
            CursorPathPlanner().shapePlan(
                events: [pointer],
                clicks: [handClick, repeatedClick]
            ),
            [
                AutoEditPlan.CursorShapeKeyframe(time: 0.2, shape: .arrow),
                AutoEditPlan.CursorShapeKeyframe(time: 0.8, shape: .pointingHand)
            ]
        )
    }

    private func makeEvent(time: Double, x: Double, y: Double) -> PointerEvent {
        PointerEvent(
            time: time,
            kind: .moved,
            location: LensPoint(x: x * 1000, y: y * 1000),
            normalizedLocation: LensPoint(x: x, y: y),
            displayID: 1
        )
    }

    private func range(_ values: [Double]) -> Double {
        (values.max() ?? 0) - (values.min() ?? 0)
    }
}
