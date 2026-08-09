import XCTest
@testable import ScreenTraceCore

final class EffectTimelineTests: XCTestCase {
    func testCameraStateInterpolatesScaleAndCenter() {
        let keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: TracePoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2,
                center: TracePoint(x: 0.75, y: 0.25),
                easing: "linear",
                reason: .clickFocus
            )
        ]
        let state = EffectTimeline.cameraState(at: 0.5, keyframes: keyframes)
        XCTAssertEqual(state.scale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(state.center.x, 0.625, accuracy: 0.0001)
        XCTAssertEqual(state.center.y, 0.375, accuracy: 0.0001)
    }

    func testCameraUsesFirstAndLastStateOutsideTimeline() {
        let keyframes = [
            frame(time: 1, scale: 1.2),
            frame(time: 2, scale: 1.8)
        ]
        XCTAssertEqual(EffectTimeline.cameraState(at: 0, keyframes: keyframes).scale, 1.2)
        XCTAssertEqual(EffectTimeline.cameraState(at: 4, keyframes: keyframes).scale, 1.8)
    }

    func testCursorPositionInterpolatesAndTracksLastActivity() {
        let keyframes = [
            AutoEditPlan.CursorKeyframe(time: 1, position: TracePoint(x: 0, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 2, position: TracePoint(x: 1, y: 1))
        ]
        let position = try! XCTUnwrap(EffectTimeline.cursorPosition(at: 1.5, keyframes: keyframes))
        XCTAssertEqual(position.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(position.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(EffectTimeline.lastCursorActivity(at: 1.5, keyframes: keyframes), 1)
    }

    func testEffectiveCameraStateAppliesIntensityAndOffMode() {
        let keyframes = [frame(time: 0, scale: 1.42)]
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.84,
            followPointer: true,
            keyframes: keyframes
        )

        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 0, camera: camera).scale,
            1.84,
            accuracy: 0.0001
        )
        var disabled = camera
        disabled.mode = "off"
        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 0, camera: disabled).scale,
            1,
            accuracy: 0.0001
        )
    }

    private func frame(time: Double, scale: Double) -> AutoEditPlan.CameraKeyframe {
        AutoEditPlan.CameraKeyframe(
            time: time,
            scale: scale,
            center: TracePoint(x: 0.5, y: 0.5),
            easing: "linear",
            reason: .baseline
        )
    }
}
