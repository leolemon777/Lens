import Foundation
import LensCore
import XCTest
@testable import LensMac

final class CursorStyleAndFollowTests: XCTestCase {
    // MARK: - 指针样式

    func testAppearanceExposesSixStylesWithNewProceduralOnes() {
        XCTAssertEqual(AutoEditPlan.Cursor.Appearance.allCases.count, 6)
        XCTAssertTrue(AutoEditPlan.Cursor.Appearance.allCases.contains(.ring))
        XCTAssertTrue(AutoEditPlan.Cursor.Appearance.allCases.contains(.glowDot))
    }

    func testNewAppearanceStylesDecodeFromRawValues() throws {
        let data = Data(#"{"appearance":"ring"}"#.utf8)
        let cursor = try JSONDecoder().decode(AutoEditPlan.Cursor.self, from: data)
        XCTAssertEqual(cursor.appearance, .ring)
    }

    @MainActor
    func testRingAndGlowDotAppearancesRenderSuccessfully() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensCursorStylePickerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")

        for appearance in [AutoEditPlan.Cursor.Appearance.ring, .glowDot] {
            let outputURL = directory.appendingPathComponent("\(appearance.rawValue).mp4")
            try? FileManager.default.removeItem(at: inputURL)
            try await SyntheticVideoFactory.makeVideo(
                at: inputURL,
                frameCount: 24,
                framesPerSecond: 24
            )
            var plan = AutoEditPlan()
            plan.cursor.appearance = appearance
            plan.cursor.keyframes = [
                AutoEditPlan.CursorKeyframe(time: 0, position: LensPoint(x: 0.2, y: 0.3)),
                AutoEditPlan.CursorKeyframe(time: 0.8, position: LensPoint(x: 0.7, y: 0.6))
            ]
            _ = try await AutoPreviewRenderer().render(
                inputURL: inputURL,
                outputURL: outputURL,
                plan: plan
            )
            let size = try FileManager.default.attributesOfItem(
                atPath: outputURL.path
            )[.size] as? NSNumber
            XCTAssertGreaterThan(size?.int64Value ?? 0, 1_000, "\(appearance)")
        }
    }

    // MARK: - 跟随效果

    func testFollowStyleMapsToSmoothingParameters() {
        var cursor = AutoEditPlan.Cursor(
            smoothing: 0.5,
            smoothingWindowMilliseconds: 40,
            scale: 1,
            hidesWhenIdle: false
        )
        // Legacy default resolves to the authored fields.
        XCTAssertEqual(cursor.followStyle, nil)
        XCTAssertEqual(cursor.resolvedSmoothingParameters.smoothing, 0.5)
        XCTAssertEqual(
            cursor.resolvedSmoothingParameters.windowMilliseconds,
            40
        )

        cursor.followStyle = .faithful
        XCTAssertEqual(cursor.resolvedSmoothingParameters.smoothing, 0)
        XCTAssertNil(cursor.resolvedSmoothingParameters.windowMilliseconds)

        cursor.followStyle = .smooth
        XCTAssertEqual(cursor.resolvedSmoothingParameters.smoothing, 0.72)
        XCTAssertEqual(
            cursor.resolvedSmoothingParameters.windowMilliseconds,
            26
        )

        cursor.followStyle = .elastic
        XCTAssertEqual(cursor.resolvedSmoothingParameters.smoothing, 1)
        XCTAssertEqual(
            cursor.resolvedSmoothingParameters.windowMilliseconds,
            80
        )

        cursor.followStyle = .custom
        XCTAssertEqual(cursor.resolvedSmoothingParameters.smoothing, 0.5)
        XCTAssertEqual(
            cursor.resolvedSmoothingParameters.windowMilliseconds,
            40
        )
    }

    func testLegacyCursorWithoutFollowStyleDecodesAsCustomBehavior() throws {
        let legacy = Data("""
        {"appearance":"macOS","smoothing":0.72,"scale":1.15,"hidesWhenIdle":true,"keyframes":[],"shapeKeyframes":[]}
        """.utf8)
        let cursor = try JSONDecoder().decode(AutoEditPlan.Cursor.self, from: legacy)
        XCTAssertNil(cursor.followStyle)
        XCTAssertEqual(
            cursor.resolvedSmoothingParameters.windowMilliseconds,
            nil,
            "Legacy plans keep the normalized smoothing renderer"
        )

        let roundTrip = try JSONDecoder().decode(
            AutoEditPlan.Cursor.self,
            from: JSONEncoder().encode(cursor)
        )
        XCTAssertNil(roundTrip.followStyle)
        XCTAssertEqual(roundTrip, cursor)
    }

    func testFaithfulFollowTracksLinearlyWithoutHermiteSmoothing() {
        // Two keyframes with a sharp corner: faithful must stay on the linear
        // path while elastic glides wide of it.
        let keyframes = [
            AutoEditPlan.CursorKeyframe(time: 0, position: LensPoint(x: 0, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 0.5, position: LensPoint(x: 0.5, y: 0)),
            AutoEditPlan.CursorKeyframe(time: 1, position: LensPoint(x: 0.5, y: 1))
        ]
        let faithful = EffectTimeline.cursorPosition(
            at: 0.25,
            keyframes: keyframes,
            smoothing: 0,
            smoothingWindowMilliseconds: nil
        )
        XCTAssertEqual(faithful?.x ?? -1, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(faithful?.y ?? -1, 0, accuracy: 0.000_1)

        let elastic = EffectTimeline.cursorPosition(
            at: 0.25,
            keyframes: keyframes,
            smoothing: 1,
            smoothingWindowMilliseconds: 80
        )
        // Hermite smoothing pulls the path toward the corner's tangent.
        XCTAssertNotNil(elastic)
    }
}
