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
        model.updateAudioLevels(system: 0.72, microphone: 0.94)
        XCTAssertEqual(model.systemAudioLevel, 0.72, accuracy: 0.001)
        XCTAssertEqual(model.microphoneAudioLevel, 0.94, accuracy: 0.001)
        XCTAssertEqual(
            model.updateAvailableStorageBytes(4 * 1_024 * 1_024 * 1_024),
            .warning
        )
        XCTAssertTrue(model.storageLabel.hasPrefix("磁盘 "))

        let root = ZStack {
            Color(red: 0.55, green: 0.55, blue: 0.55)
            RecordingControlView(model: model, onPauseToggle: {}, onStop: {})
        }
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 550, height: 98)
        let snapshotWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.appearance = NSAppearance(named: .aqua)
        snapshotWindow.contentView = hostingView
        snapshotWindow.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        snapshotWindow.orderFront(nil)
        defer { snapshotWindow.orderOut(nil) }
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create recording control snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])
        if let snapshotPath = ProcessInfo.processInfo.environment[
            "SCREENTRACE_RECORDING_CONTROL_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 550)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 98)
        XCTAssertGreaterThan(png?.count ?? 0, 4_000)
    }

    func testStorageStatusWarnsBeforeItRequiresASafeStop() throws {
        let gibibyte: Int64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(RecordingControlModel.storageLevel(for: nil), .unknown)
        XCTAssertEqual(RecordingControlModel.storageLevel(for: 6 * gibibyte), .healthy)
        XCTAssertEqual(RecordingControlModel.storageLevel(for: 5 * gibibyte), .warning)
        XCTAssertEqual(RecordingControlModel.storageLevel(for: gibibyte), .critical)
        XCTAssertEqual(RecordingControlModel.storageLevel(for: -1), .critical)

        let nonexistentChild = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("future-project", isDirectory: true)
        let available = RecordingControlWindowController.availableStorageBytes(
            at: nonexistentChild
        )
        XCTAssertNotNil(available)
        XCTAssertGreaterThan(available ?? 0, 0)

        let controller = RecordingControlWindowController()
        var criticalReports: [Int64?] = []
        controller.onCriticalStorage = { criticalReports.append($0) }
        controller.applyAvailableStorageBytes(2 * gibibyte)
        XCTAssertTrue(criticalReports.isEmpty)
        controller.applyAvailableStorageBytes(gibibyte)
        controller.applyAvailableStorageBytes(gibibyte / 2)
        XCTAssertEqual(criticalReports.count, 1)
        XCTAssertEqual(criticalReports[0], gibibyte)
    }
}
