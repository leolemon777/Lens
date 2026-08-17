import XCTest
@testable import ScreenTraceCore

final class CameraMotionComfortAnalyzerTests: XCTestCase {
    func testLegacyFixedShortTransitionsFailRestrainedComfortBudget() {
        let report = CameraMotionComfortAnalyzer.analyze(
            keyframes: [
                frame(time: 0, scale: 1, x: 0.5, reason: .baseline),
                frame(time: 1, scale: 1, x: 0.5, reason: .baseline),
                frame(time: 1.82, scale: 1.6, x: 0.3125, reason: .clickFocus),
                frame(time: 2.2, scale: 1.6, x: 0.3125, reason: .clickHold),
                frame(time: 3.02, scale: 1.6, x: 0.6875, reason: .clickFocus)
            ],
            durationSeconds: 5,
            limits: .recommended(for: .restrained)
        )

        XCTAssertFalse(report.isComfortable)
        XCTAssertTrue(report.issues.contains(.excessivePanVelocity))
        XCTAssertTrue(report.issues.contains(.excessiveZoomVelocity))
    }

    func testDistanceAwareRestrainedPlannerStaysInsideComfortBudget() {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: true,
            zoomScale: 1.6,
            generationStrength: .restrained
        )
        let keyframes = AutoCameraPlanner(camera: camera).plan(
            clicks: [
                click(time: 1, x: 0.2),
                click(time: 3.2, x: 0.8),
                click(time: 6, x: 0.25)
            ],
            duration: 10
        )
        var plannedCamera = camera
        plannedCamera.keyframes = keyframes

        let report = CameraMotionComfortAnalyzer.analyze(
            camera: plannedCamera,
            durationSeconds: 10
        )

        XCTAssertTrue(report.isComfortable, "Unexpected issues: \(report.issues)")
        XCTAssertLessThanOrEqual(report.maximumPanVelocity, 0.75 * 1.02)
        XCTAssertLessThanOrEqual(report.maximumZoomVelocity, 1.25 * 1.02)
        XCTAssertEqual(report.compressedReturnCount, 0)
    }

    func testCompressedReturnAtMediaBoundaryIsReported() {
        let report = CameraMotionComfortAnalyzer.analyze(
            keyframes: [
                frame(time: 0, scale: 1.6, x: 0.3, reason: .clickHold),
                frame(time: 0.5, scale: 1, x: 0.5, reason: .returnToOverview)
            ],
            durationSeconds: 0.5,
            limits: .recommended(for: .restrained)
        )

        XCTAssertFalse(report.isComfortable)
        XCTAssertEqual(report.compressedReturnCount, 1)
        XCTAssertTrue(report.issues.contains(.compressedReturn))
    }

    func testStableCameraHasNoComfortIssues() {
        let report = CameraMotionComfortAnalyzer.analyze(
            keyframes: [
                frame(time: 0, scale: 1, x: 0.5, reason: .baseline),
                frame(time: 30, scale: 1, x: 0.5, reason: .baseline)
            ],
            durationSeconds: 30,
            limits: .recommended(for: .restrained)
        )

        XCTAssertTrue(report.isComfortable)
        XCTAssertEqual(report.analyzedTransitionCount, 0)
    }

    private func frame(
        time: Double,
        scale: Double,
        x: Double,
        reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> AutoEditPlan.CameraKeyframe {
        AutoEditPlan.CameraKeyframe(
            time: time,
            scale: scale,
            center: TracePoint(x: x, y: 0.5),
            easing: reason == .clickFocus
                ? "ease-in-out-smootherstep"
                : reason == .returnToOverview
                    ? "critically-damped"
                    : "linear",
            reason: reason
        )
    }

    private func click(time: Double, x: Double) -> ClickEvent {
        ClickEvent(
            time: time,
            button: .left,
            phase: .down,
            location: TracePoint(x: x * 1_000, y: 500),
            normalizedLocation: TracePoint(x: x, y: 0.5),
            displayID: 1,
            clickCount: 1
        )
    }
}
