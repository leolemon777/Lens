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
            capturesMicrophone: true,
            capturesCamera: true
        )
        XCTAssertEqual(model.sourceTitle, "窗口录制")
        XCTAssertFalse(model.capturesSystemAudio)
        XCTAssertTrue(model.capturesMicrophone)
        XCTAssertTrue(model.capturesCamera)
        XCTAssertEqual(model.elapsed(at: model.startedAt.addingTimeInterval(65)), 65, accuracy: 0.001)

        let pauseDate = model.startedAt.addingTimeInterval(30)
        model.setPaused(true, at: pauseDate)
        XCTAssertEqual(model.elapsed(at: pauseDate.addingTimeInterval(20)), 30, accuracy: 0.001)
        model.setPaused(false, at: pauseDate.addingTimeInterval(20))
        XCTAssertEqual(model.elapsed(at: pauseDate.addingTimeInterval(35)), 45, accuracy: 0.001)

        let root = RecordingControlView(model: model, onPauseToggle: {}, onStop: {})
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 430, height: 98)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create recording control snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 430)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 98)
        XCTAssertGreaterThan(png?.count ?? 0, 4_000)
    }
}
