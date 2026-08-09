import AppKit
import SwiftUI
import XCTest
@testable import ScreenTraceMac

@MainActor
final class RecordingControlViewTests: XCTestCase {
    func testControlModelAndGlassBarRenderSelectedSource() throws {
        let model = RecordingControlModel()
        model.reset(
            sourceTitle: "窗口录制",
            capturesSystemAudio: false,
            capturesMicrophone: true
        )
        XCTAssertEqual(model.sourceTitle, "窗口录制")
        XCTAssertFalse(model.capturesSystemAudio)
        XCTAssertTrue(model.capturesMicrophone)
        XCTAssertEqual(model.elapsed(at: model.startedAt.addingTimeInterval(65)), 65, accuracy: 0.001)

        let root = RecordingControlView(model: model, onStop: {})
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 400, height: 98)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create recording control snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 400)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 98)
        XCTAssertGreaterThan(png?.count ?? 0, 4_000)
    }
}
