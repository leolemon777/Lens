import Foundation
import XCTest
@testable import ScreenTraceCore

final class PresenterCameraPlacementPlannerTests: XCTestCase {
    func testLegacyPresenterCameraDecodesWithNewDefaults() throws {
        let data = try XCTUnwrap(
            """
            {
              "isEnabled": true,
              "shape": "circle",
              "anchor": "bottomTrailing",
              "size": 0.19,
              "margin": 0.035,
              "cornerRadius": 0.08,
              "isMirrored": true,
              "shadowOpacity": 0.3
            }
            """.data(using: .utf8)
        )

        let layout = try JSONDecoder().decode(AutoEditPlan.PresenterCamera.self, from: data)

        XCTAssertNil(layout.position)
        XCTAssertTrue(layout.automaticallyAvoidsContent)
        XCTAssertTrue(layout.keyframes.isEmpty)
        XCTAssertNoThrow(try JSONEncoder().encode(layout))
    }

    func testAnchorUsesActualCanvasAspectRatio() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .roundedRectangle,
            anchor: .topLeading,
            size: 0.4,
            margin: 0.1,
            automaticallyAvoidsContent: false
        )

        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            canvasAspectRatio: 1
        )

        XCTAssertEqual(state.center.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(state.center.y, 0.2125, accuracy: 0.0001)
    }

    func testBottomCaptionMovesConflictingCameraToTop() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.28,
            margin: 0.035
        )
        let captions = AutoEditPlan.Captions(isEnabled: true, position: .bottom)

        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            captions: captions
        )

        XCTAssertGreaterThan(state.center.x, 0.5)
        XCTAssertLessThan(state.center.y, 0.5)
    }

    func testCaptionAvoidanceAmountInterpolatesMovementWithoutJumping() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.28
        )
        let captions = AutoEditPlan.Captions(isEnabled: true, position: .bottom)
        let idle = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            captions: captions,
            captionAvoidanceAmount: 0
        )
        let moving = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            captions: captions,
            captionAvoidanceAmount: 0.5
        )
        let avoided = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            captions: captions,
            captionAvoidanceAmount: 1
        )

        XCTAssertGreaterThan(idle.center.y, moving.center.y)
        XCTAssertGreaterThan(moving.center.y, avoided.center.y)
    }

    func testClickFocusMovesCameraToFarthestCorner() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.24
        )
        let cameraKeyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1.42,
                center: TracePoint(x: 0.9, y: 0.9),
                easing: "linear",
                reason: .clickFocus
            )
        ]

        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            cameraKeyframes: cameraKeyframes
        )

        XCTAssertLessThan(state.center.x, 0.5)
        XCTAssertLessThan(state.center.y, 0.5)
    }

    func testCenteredClickFocusKeepsNonOverlappingCornerStable() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .roundedRectangle,
            anchor: .bottomTrailing,
            size: 0.24
        )
        let baseline = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout
        )
        let focused = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            cameraKeyframes: [
                AutoEditPlan.CameraKeyframe(
                    time: 0,
                    scale: 1.42,
                    center: TracePoint(x: 0.5, y: 0.5),
                    easing: "linear",
                    reason: .clickFocus
                )
            ]
        )

        XCTAssertEqual(focused.center.x, baseline.center.x, accuracy: 0.0001)
        XCTAssertEqual(focused.center.y, baseline.center.y, accuracy: 0.0001)
    }

    func testUltraWideCanvasShrinksCircleToFitVerticalSafeArea() {
        let layout = AutoEditPlan.PresenterCamera(
            shape: .circle,
            anchor: .bottomTrailing,
            size: 0.45,
            margin: 0.05,
            automaticallyAvoidsContent: false
        )

        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            canvasAspectRatio: 4
        )

        XCTAssertEqual(state.size, 0.225, accuracy: 0.0001)
        XCTAssertEqual(state.center.y, 0.5, accuracy: 0.0001)
    }

    func testManualKeyframesInterpolatePositionAndSizeInSourceTime() {
        let layout = AutoEditPlan.PresenterCamera(
            size: 0.1,
            position: TracePoint(x: 0.2, y: 0.2),
            automaticallyAvoidsContent: false,
            keyframes: [
                AutoEditPlan.PresenterCameraKeyframe(
                    sourceTimeSeconds: 2,
                    center: TracePoint(x: 0.8, y: 0.8),
                    size: 0.3,
                    easing: "linear"
                )
            ]
        )

        let state = PresenterCameraPlacementPlanner.state(
            atSourceTime: 1,
            layout: layout
        )

        XCTAssertEqual(state.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.center.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.size, 0.2, accuracy: 0.0001)
    }
}
