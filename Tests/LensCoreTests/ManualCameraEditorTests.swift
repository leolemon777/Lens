import XCTest
@testable import LensCore

final class ManualCameraEditorTests: XCTestCase {
    func testManualFocusCreatesAClampedCinematicSequence() {
        let editor = ManualCameraEditor(configuration: .init(
            transitionDuration: 0.25,
            holdDuration: 1,
            returnDuration: 0.4
        ))
        let updated = editor.insertingFocus(
            at: 2,
            center: LensPoint(x: 1, y: 0),
            scale: 2,
            duration: 6,
            into: AutoEditPlan().camera
        )

        let manual = updated.keyframes.filter {
            ManualCameraEditor.isManual($0.reason)
        }
        XCTAssertEqual(
            manual.map(\.reason),
            [.manualAnchor, .manualFocus, .manualHold, .manualReturn]
        )
        XCTAssertEqual(manual.map(\.time), [1.75, 2, 3, 3.4])
        XCTAssertEqual(manual[1].center.x, 0.75, accuracy: 0.000_1)
        XCTAssertEqual(manual[1].center.y, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(manual.last?.scale, 1)
    }

    func testManualFocusOverridesAutomaticFramesOnlyInsideItsInterval() {
        var camera = AutoEditPlan().camera
        camera.keyframes = [
            frame(time: 0, reason: .baseline),
            frame(time: 1.9, reason: .clickFocus),
            frame(time: 2.5, reason: .pointerFollow),
            frame(time: 5, reason: .clickFocus)
        ]

        let updated = ManualCameraEditor().insertingFocus(
            at: 2,
            center: LensPoint(x: 0.4, y: 0.6),
            scale: 1.9,
            duration: 8,
            into: camera
        )

        XCTAssertTrue(updated.keyframes.contains { $0.time == 0 && $0.reason == .baseline })
        XCTAssertFalse(updated.keyframes.contains { $0.time == 1.9 && $0.reason == .clickFocus })
        XCTAssertFalse(updated.keyframes.contains { $0.time == 2.5 && $0.reason == .pointerFollow })
        XCTAssertTrue(updated.keyframes.contains { $0.time == 5 && $0.reason == .clickFocus })
    }

    func testClearingManualFocusPreservesAutomaticCameraPlan() {
        var camera = AutoEditPlan().camera
        camera.keyframes = [
            frame(time: 0, reason: .baseline),
            frame(time: 1, reason: .manualFocus),
            frame(time: 2, reason: .manualReturn),
            frame(time: 3, reason: .clickFocus)
        ]

        let cleared = ManualCameraEditor().removingManualKeyframes(from: camera)

        XCTAssertEqual(cleared.keyframes.map(\.reason), [.baseline, .clickFocus])
    }

    private func frame(
        time: Double,
        reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> AutoEditPlan.CameraKeyframe {
        AutoEditPlan.CameraKeyframe(
            time: time,
            scale: reason == .baseline ? 1 : 1.6,
            center: LensPoint(x: 0.5, y: 0.5),
            easing: "linear",
            reason: reason
        )
    }
}
