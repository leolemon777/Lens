import XCTest
@testable import LensCore

final class AutoCameraPlannerTests: XCTestCase {
    func testNoClicksKeepsOverviewOnly() {
        let result = AutoCameraPlanner().plan(clicks: [], duration: 10)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].reason, .baseline)
        XCTAssertEqual(result[0].scale, 1)
    }

    func testMeaningfulPointerMovementWithoutClicksCreatesGentleFollow() {
        let pointers = stride(from: 1.0, through: 2.0, by: 0.10).enumerated().map {
            index, time in
            PointerEvent(
                time: time,
                kind: .moved,
                location: LensPoint(x: Double(180 + index * 65), y: 420),
                normalizedLocation: LensPoint(
                    x: Double(180 + index * 65) / 1_000,
                    y: 0.42
                ),
                displayID: 1
            )
        }

        let result = AutoCameraPlanner().plan(
            clicks: [],
            pointerEvents: pointers,
            followPointer: true,
            duration: 5
        )

        XCTAssertTrue(result.contains { $0.reason == .pointerFollow })
        XCTAssertGreaterThan(result.map(\.scale).max() ?? 1, 1.2)
        XCTAssertEqual(result.last?.reason, .returnToOverview)
        XCTAssertEqual(result.last?.scale, 1)
    }

    func testTinyPointerJitterWithoutClicksDoesNotMoveCamera() {
        let pointers = (0..<12).map { index in
            PointerEvent(
                time: Double(index) * 0.1,
                kind: .moved,
                location: LensPoint(x: 500 + Double(index % 2), y: 500),
                normalizedLocation: LensPoint(
                    x: 0.5 + Double(index % 2) * 0.001,
                    y: 0.5
                ),
                displayID: 1
            )
        }

        let result = AutoCameraPlanner().plan(
            clicks: [],
            pointerEvents: pointers,
            followPointer: true,
            duration: 5
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].scale, 1)
    }

    /// A slow approach is many sub-threshold steps. Dropping each one before
    /// it can accumulate hid the exact moment a presenter is lining up a click.
    func testSlowPointerApproachAccumulatesIntoFollowableActivity() {
        let pointers = (0...40).map { index in
            pointer(time: Double(index) * 0.05, x: 0.20 + Double(index) * 0.002)
        }

        let result = AutoCameraPlanner().plan(
            clicks: [],
            pointerEvents: pointers,
            followPointer: true,
            duration: 5
        )

        XCTAssertTrue(
            result.contains { $0.reason == .pointerFollow },
            "精细挪动被单步阈值丢掉了，整段活动应该累计后进入特写"
        )
    }

    func testPointerFollowCanBeDisabledEvenWhenMovementIsMeaningful() {
        let pointers = [
            pointer(time: 1, x: 0.2),
            pointer(time: 1.4, x: 0.8)
        ]
        let result = AutoCameraPlanner().plan(
            clicks: [],
            pointerEvents: pointers,
            followPointer: false,
            duration: 4
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].scale, 1)
    }

    func testGenerationStrengthChangesShotClusteringAndKeepsAbsoluteScale() {
        let clicks = [
            makeClick(time: 1, x: 0.3, y: 0.5),
            makeClick(time: 3, x: 0.7, y: 0.5)
        ]
        let restrainedCamera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.44,
            generationStrength: .restrained
        )
        let activeCamera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.44,
            generationStrength: .active
        )

        let restrained = AutoCameraPlanner(camera: restrainedCamera).plan(
            clicks: clicks,
            duration: 6
        )
        let active = AutoCameraPlanner(camera: activeCamera).plan(
            clicks: clicks,
            duration: 6
        )

        let restrainedFocus = restrained.first { $0.reason == .clickFocus }
        let activeFocus = active.first { $0.reason == .clickFocus }
        XCTAssertGreaterThan(
            restrainedFocus?.time ?? 0,
            activeFocus?.time ?? 0
        )
        XCTAssertGreaterThan(
            restrained.last?.time ?? 0,
            active.last?.time ?? 0
        )
        XCTAssertEqual(
            restrained.first { $0.reason == .clickFocus }?.scale,
            1.44
        )
        XCTAssertEqual(active.first { $0.reason == .clickFocus }?.scale, 1.44)
    }

    func testClickCreatesFocusHoldAndReturn() {
        let click = makeClick(time: 1, x: 0.5, y: 0.5)
        let result = AutoCameraPlanner().plan(clicks: [click], duration: 4)

        XCTAssertEqual(
            result.filter { $0.reason != .baseline }.map(\.reason),
            [.clickFocus, .clickHold, .returnToOverview]
        )
        XCTAssertGreaterThan(
            result.first { $0.reason == .clickFocus }?.scale ?? 1,
            1
        )
        XCTAssertEqual(result.last?.scale, 1)
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { $0.time <= $1.time })
    }

    func testDefaultClickAppearsBeforeCameraCarriesTargetToCenter() throws {
        let clickTime = 2.0
        let result = AutoCameraPlanner().plan(
            clicks: [makeClick(time: clickTime, x: 0.72, y: 0.46)],
            duration: 5
        )
        let focus = try XCTUnwrap(result.first { $0.reason == .clickFocus })
        let anchor = try XCTUnwrap(result.last {
            $0.reason == .baseline && $0.time < focus.time
        })

        XCTAssertEqual(anchor.time, clickTime, accuracy: 0.000_1)
        XCTAssertGreaterThan(focus.time, clickTime + 0.62)
        XCTAssertEqual(
            focus.time - anchor.time,
            log2(1.6) * 1.875 / 1.6,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            EffectTimeline.cameraState(at: clickTime, keyframes: result).scale,
            1,
            accuracy: 0.000_1
        )
        XCTAssertGreaterThan(
            EffectTimeline.cameraState(at: clickTime + 0.31, keyframes: result).scale,
            1
        )
    }

    func testRetargetHoldsCompositionUntilTheNextClick() throws {
        let result = AutoCameraPlanner().plan(
            clicks: [
                makeClick(time: 1, x: 0.25, y: 0.5),
                makeClick(time: 2, x: 0.75, y: 0.5)
            ],
            duration: 5
        )
        let focusFrames = result.filter { $0.reason == .clickFocus }
        XCTAssertEqual(focusFrames.count, 2)
        let firstFocus = try XCTUnwrap(focusFrames.first)
        let retargetAnchor = try XCTUnwrap(result.first {
            $0.reason == .clickHold && abs($0.time - 2.0) < 0.000_1
        })

        XCTAssertEqual(retargetAnchor.center, firstFocus.center)
        XCTAssertEqual(
            EffectTimeline.cameraState(at: 1.99, keyframes: result).center,
            firstFocus.center
        )
    }

    func testFirstZoomWaitsUntilTheShortLeadInInsteadOfDriftingFromVideoStart() {
        let planner = AutoCameraPlanner(configuration: .init(
            focusLeadIn: 0.10,
            zoomDuration: 0.20
        ))
        let result = planner.plan(
            clicks: [makeClick(time: 2, x: 0.75, y: 0.5)],
            duration: 5
        )

        XCTAssertEqual(
            EffectTimeline.cameraState(at: 1.89, keyframes: result).scale,
            1,
            accuracy: 0.000_1
        )
        XCTAssertGreaterThan(
            EffectTimeline.cameraState(at: 2.05, keyframes: result).scale,
            1
        )
    }

    func testNearbyRepeatedClicksExtendFocusWithoutPumpingTheZoom() {
        let result = AutoCameraPlanner().plan(
            clicks: [
                makeClick(time: 1, x: 0.50, y: 0.50),
                makeClick(time: 1.35, x: 0.53, y: 0.52),
                makeClick(time: 1.70, x: 0.51, y: 0.49)
            ],
            duration: 4
        )

        XCTAssertEqual(result.count { $0.reason == .clickFocus }, 1)
        XCTAssertGreaterThan(
            result.first { $0.reason == .clickHold }?.time ?? 0,
            2.5
        )
    }

    func testClicksInsideCurrentFocusSafeAreaKeepTheExistingComposition() {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.60,
            generationStrength: .restrained
        )
        let result = AutoCameraPlanner(camera: camera).plan(
            clicks: [
                makeClick(time: 1, x: 0.35, y: 0.50),
                makeClick(time: 2.20, x: 0.49, y: 0.56),
                makeClick(time: 3.40, x: 0.42, y: 0.42)
            ],
            duration: 7
        )

        XCTAssertEqual(result.count { $0.reason == .clickFocus }, 1)
        XCTAssertEqual(result.count { $0.reason == .returnToOverview }, 1)
        XCTAssertGreaterThan(
            result.first { $0.reason == .clickHold }?.time ?? 0,
            5
        )
    }

    func testRestrainedCameraDoesNotPumpAcrossAShortIdleGap() {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.60,
            generationStrength: .restrained
        )
        let result = AutoCameraPlanner(camera: camera).plan(
            clicks: [
                makeClick(time: 1, x: 0.25, y: 0.50),
                makeClick(time: 4, x: 0.75, y: 0.50)
            ],
            duration: 8
        )
        let focusIndices = result.indices.filter { result[$0].reason == .clickFocus }
        XCTAssertEqual(focusIndices.count, 2)
        XCTAssertFalse(result[(focusIndices[0] + 1)..<focusIndices[1]].contains {
            $0.reason == .returnToOverview
        })
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

    func testFarClickUsesLongerTransitionThanNearbyClick() throws {
        let nearby = AutoCameraPlanner().plan(
            clicks: [makeClick(time: 1, x: 0.55, y: 0.5)],
            duration: 5
        )
        let far = AutoCameraPlanner().plan(
            clicks: [makeClick(time: 1, x: 0.9, y: 0.1)],
            duration: 5
        )
        let nearbyFocus = try XCTUnwrap(nearby.first { $0.reason == .clickFocus })
        let farFocus = try XCTUnwrap(far.first { $0.reason == .clickFocus })

        XCTAssertGreaterThan(farFocus.time - 1, nearbyFocus.time - 1)
        XCTAssertGreaterThanOrEqual(nearbyFocus.time - 1, 0.62)
        XCTAssertLessThanOrEqual(farFocus.time - 1, 1.55)
    }

    func testFinalClickPrioritizesReturningToOverviewBeforeMediaEnd() throws {
        let result = AutoCameraPlanner(camera: AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            zoomScale: 1.60,
            generationStrength: .restrained
        )).plan(
            clicks: [makeClick(time: 2.8, x: 0.5, y: 0.5)],
            duration: 5
        )

        let focus = try XCTUnwrap(result.first { $0.reason == .clickFocus })
        let hold = try XCTUnwrap(result.first { $0.reason == .clickHold })
        let overview = try XCTUnwrap(result.last { $0.reason == .returnToOverview })

        XCTAssertGreaterThan(hold.time, focus.time)
        XCTAssertEqual(overview.time - hold.time, 1.15, accuracy: 0.000_1)
        XCTAssertEqual(result.last?.reason, .returnToOverview)
        XCTAssertEqual(result.last?.time, 5)
        XCTAssertEqual(result.last?.scale, 1)
        XCTAssertEqual(result.last?.center, LensPoint(x: 0.5, y: 0.5))
    }

    func testClickTooCloseToMediaEndDoesNotForceACompressedZoom() {
        let result = AutoCameraPlanner(camera: AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            zoomScale: 1.60,
            generationStrength: .restrained
        )).plan(
            clicks: [makeClick(time: 4.1, x: 0.2, y: 0.7)],
            duration: 5
        )

        XCTAssertFalse(result.contains { $0.reason == .clickFocus })
        XCTAssertFalse(result.contains { $0.reason == .returnToOverview })
        XCTAssertEqual(result.last?.reason, .baseline)
        XCTAssertEqual(result.last?.time, 4.1)
        XCTAssertEqual(result.last?.scale, 1)
    }

    func testMouseUpAndClicksOutsideCaptureAreIgnored() {
        let withoutNormalized = ClickEvent(
            time: 1,
            button: .left,
            phase: .down,
            location: LensPoint(x: 100, y: 100),
            clickCount: 1
        )
        let mouseUp = ClickEvent(
            time: 2,
            button: .left,
            phase: .up,
            location: LensPoint(x: 100, y: 100),
            normalizedLocation: LensPoint(x: 0.5, y: 0.5),
            clickCount: 1
        )
        XCTAssertEqual(
            AutoCameraPlanner().plan(clicks: [withoutNormalized, mouseUp], duration: 4).count,
            1
        )
    }

    func testClickTargetStaysFixedWhilePointerMovesElsewhere() {
        let pointers = stride(from: 1.25, through: 1.85, by: 0.10).enumerated().map {
            index, time in
            PointerEvent(
                time: time,
                kind: .moved,
                location: LensPoint(x: Double(300 + index * 70), y: 500),
                normalizedLocation: LensPoint(
                    x: Double(300 + index * 70) / 1000,
                    y: 0.5
                ),
                displayID: 1
            )
        }
        let followed = AutoCameraPlanner().plan(
            clicks: [makeClick(time: 1, x: 0.3, y: 0.5)],
            pointerEvents: pointers,
            followPointer: true,
            duration: 4
        )
        let fixed = AutoCameraPlanner().plan(
            clicks: [makeClick(time: 1, x: 0.3, y: 0.5)],
            pointerEvents: pointers,
            followPointer: false,
            duration: 4
        )

        XCTAssertFalse(followed.contains { $0.reason == .pointerFollow })
        XCTAssertFalse(fixed.contains { $0.reason == .pointerFollow })
        XCTAssertEqual(followed, fixed)
        let focus = followed.first { $0.reason == .clickFocus }
        XCTAssertEqual(focus?.center.x ?? -1, 0.3125, accuracy: 0.000_1)
    }

    func testScrollInertiaLocksCompositionAndDefersClickRefocus() throws {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.60,
            generationStrength: .restrained
        )
        let pointers = [
            pointer(time: 1.45, x: 0.25),
            scroll(time: 1.70, x: 0.25, deltaY: -18),
            scroll(time: 1.82, x: 0.25, deltaY: -12),
            pointer(time: 1.95, x: 0.88),
            pointer(time: 2.62, x: 0.88)
        ]
        let result = AutoCameraPlanner(camera: camera).plan(
            clicks: [
                makeClick(time: 1, x: 0.25, y: 0.5),
                makeClick(time: 1.78, x: 0.78, y: 0.5)
            ],
            pointerEvents: pointers,
            duration: 6
        )
        let focusFrames = result.filter { $0.reason == .clickFocus }
        let deferredFocus = try XCTUnwrap(focusFrames.last)

        XCTAssertEqual(focusFrames.count, 2)
        XCTAssertGreaterThanOrEqual(deferredFocus.time, 2.95)
        XCTAssertFalse(result.contains {
            $0.reason == .pointerFollow && (1.70...2.47).contains($0.time)
        })
    }

    private func makeClick(time: Double, x: Double, y: Double) -> ClickEvent {
        ClickEvent(
            time: time,
            button: .left,
            phase: .down,
            location: LensPoint(x: x * 1000, y: y * 1000),
            normalizedLocation: LensPoint(x: x, y: y),
            displayID: 1,
            clickCount: 1
        )
    }

    private func pointer(time: Double, x: Double) -> PointerEvent {
        PointerEvent(
            time: time,
            kind: .moved,
            location: LensPoint(x: x * 1_000, y: 500),
            normalizedLocation: LensPoint(x: x, y: 0.5),
            displayID: 1
        )
    }

    private func scroll(time: Double, x: Double, deltaY: Double) -> PointerEvent {
        PointerEvent(
            time: time,
            kind: .scroll,
            location: LensPoint(x: x * 1_000, y: 500),
            normalizedLocation: LensPoint(x: x, y: 0.5),
            displayID: 1,
            scrollDelta: LensPoint(x: 0, y: deltaY)
        )
    }
}
