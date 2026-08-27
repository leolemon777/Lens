import XCTest
@testable import LensCore

final class EffectTimelineTests: XCTestCase {
    func testCameraStateInterpolatesScaleAndCenter() {
        let keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2,
                center: LensPoint(x: 0.75, y: 0.25),
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

    func testCameraEasingCurvesAreSeekSafeAndReachExactEndpoints() {
        let smootherstep = [
            frame(time: 0, scale: 1),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "ease-in-out-smootherstep",
                reason: .clickFocus
            )
        ]
        let damped = [
            frame(time: 0, scale: 1),
            AutoEditPlan.CameraKeyframe(
                time: 1,
                scale: 2,
                center: LensPoint(x: 0.5, y: 0.5),
                easing: "critically-damped",
                reason: .clickFocus
            )
        ]

        XCTAssertEqual(EffectTimeline.cameraState(at: 0, keyframes: smootherstep).scale, 1)
        XCTAssertEqual(EffectTimeline.cameraState(at: 1, keyframes: smootherstep).scale, 2)
        XCTAssertLessThan(EffectTimeline.cameraState(at: 0.25, keyframes: smootherstep).scale, 1.25)
        XCTAssertEqual(
            EffectTimeline.cameraState(at: 0.5, keyframes: smootherstep).scale,
            1.5,
            accuracy: 0.000_1
        )
        XCTAssertEqual(EffectTimeline.cameraState(at: 0, keyframes: damped).scale, 1)
        XCTAssertEqual(EffectTimeline.cameraState(at: 1, keyframes: damped).scale, 2)
        XCTAssertGreaterThan(EffectTimeline.cameraState(at: 0.25, keyframes: damped).scale, 1.25)
    }

    func testCursorPositionInterpolatesAndTracksLastActivity() {
        let keyframes = [
            AutoEditPlan.CursorKeyframe(time: 1, position: LensPoint(x: 0, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 2, position: LensPoint(x: 1, y: 1))
        ]
        let position = try! XCTUnwrap(EffectTimeline.cursorPosition(at: 1.5, keyframes: keyframes))
        XCTAssertEqual(position.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(position.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(EffectTimeline.lastCursorActivity(at: 1.5, keyframes: keyframes), 1)
    }

    func testCursorKindUsesSeekSafeDragStateAcrossLargeTracks() {
        let keyframes = (0..<20_000).map { index in
            AutoEditPlan.CursorKeyframe(
                time: Double(index) / 60,
                position: LensPoint(x: Double(index % 100) / 100, y: 0.5),
                kind: index < 12_000 ? .moved : .dragged
            )
        }

        XCTAssertEqual(
            EffectTimeline.cursorKind(at: 210, keyframes: keyframes),
            .dragged
        )
        XCTAssertEqual(
            EffectTimeline.lastCursorActivity(at: 210, keyframes: keyframes) ?? -1,
            210,
            accuracy: 0.000_1
        )
        XCTAssertNotNil(
            EffectTimeline.cursorPosition(at: 210.005, keyframes: keyframes)
        )
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

    func testManualCameraScaleIsAbsoluteAndDoesNotChangeWithAutoIntensity() {
        let manual = AutoEditPlan.CameraKeyframe(
            time: 1,
            scale: 2.25,
            center: LensPoint(x: 0.5, y: 0.5),
            easing: "cinematic",
            reason: .manualFocus
        )
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 1,
            followPointer: true,
            keyframes: [manual]
        )

        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 1, camera: camera).scale,
            2.25,
            accuracy: 0.000_1
        )
    }

    func testNewAutomaticCameraScaleIsAbsolute() {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 1,
            followPointer: true,
            clickToZoom: true,
            zoomScale: 1.72,
            generationStrength: .balanced,
            keyframes: [frame(time: 0, scale: 1.72)]
        )

        XCTAssertEqual(
            EffectTimeline.effectiveCameraState(at: 0, camera: camera).scale,
            1.72,
            accuracy: 0.000_1
        )
    }

    func testCursorSmoothingWindowUsesMillisecondsAndZeroRestoresLinearPath() throws {
        let keyframes = [
            AutoEditPlan.CursorKeyframe(time: 0, position: LensPoint(x: 0, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 0.1, position: LensPoint(x: 0, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 0.2, position: LensPoint(x: 1, y: 1)),
            AutoEditPlan.CursorKeyframe(time: 0.3, position: LensPoint(x: 1, y: 0))
        ]
        let original = try XCTUnwrap(EffectTimeline.cursorPosition(
            at: 0.15,
            keyframes: keyframes,
            smoothingWindowMilliseconds: 0
        ))
        let smoothed = try XCTUnwrap(EffectTimeline.cursorPosition(
            at: 0.15,
            keyframes: keyframes,
            smoothingWindowMilliseconds: 80
        ))

        XCTAssertEqual(original.x, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(original.y, 0.5, accuracy: 0.000_1)
        XCTAssertNotEqual(smoothed, original)
    }

    private func frame(time: Double, scale: Double) -> AutoEditPlan.CameraKeyframe {
        AutoEditPlan.CameraKeyframe(
            time: time,
            scale: scale,
            center: LensPoint(x: 0.5, y: 0.5),
            easing: "linear",
            reason: .baseline
        )
    }
}
