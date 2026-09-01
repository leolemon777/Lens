import AppKit
import SwiftUI
import XCTest
@testable import LensMac

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
        model.updateEventCaptureHealth(.healthy(pointerCount: 12, clickCount: 2))
        XCTAssertTrue(model.eventCaptureHelp.contains("12 个光标点"))
        model.updateCapturePerformance(CapturePerformanceSnapshot(
            requestedFramesPerSecond: 60,
            receivedCompleteFrameCount: 120,
            writtenFrameCount: 118,
            droppedFrameCount: 2,
            measuredReceivedFramesPerSecond: 59.8,
            measuredWrittenFramesPerSecond: 58.9,
            p95FrameIntervalMilliseconds: 17
        ))
        XCTAssertEqual(model.frameRateLabel, "59 FPS")
        XCTAssertTrue(model.frameRateHelp.contains("写入 58.9 FPS"))
        XCTAssertTrue(model.frameRateHelp.contains("采集 59.8 FPS"))
        XCTAssertEqual(
            model.updateAvailableStorageBytes(4 * 1_024 * 1_024 * 1_024),
            .warning
        )
        XCTAssertTrue(model.storageLabel.hasPrefix("磁盘 "))

        let root = ZStack {
            Color(red: 0.55, green: 0.55, blue: 0.55)
            RecordingControlView(
                model: model,
                onHide: {},
                onPauseToggle: {},
                onDiscardAndRestart: {},
                onStop: {}
            )
        }
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: RecordingControlWindowController.panelSize)
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
            "LENS_RECORDING_CONTROL_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertLessThanOrEqual(RecordingControlWindowController.panelSize.width, 600)
        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 520)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 110)
        XCTAssertGreaterThan(png?.count ?? 0, 4_000)
    }

    func testControlModelProvidesDynamicSpokenStatus() {
        let model = RecordingControlModel()
        let startedAt = Date(timeIntervalSince1970: 100)
        model.startedAt = startedAt
        model.capturesSystemAudio = true
        model.capturesMicrophone = true
        model.updateAudioLevels(system: 0.724, microphone: 0.946)

        XCTAssertEqual(model.pauseActionTitle, "暂停录制")
        XCTAssertEqual(model.recordingStateTitle, "正在录制")
        XCTAssertEqual(model.systemAudioAccessibilityValue, "录制中，电平 72%")
        XCTAssertEqual(model.microphoneAccessibilityValue, "单独分轨录制中，电平 95%")
        model.updateEventCaptureHealth(.degraded(.eventsNotDelivered))
        XCTAssertTrue(model.eventCaptureHelp.contains("没有交付事件"))
        XCTAssertEqual(
            model.elapsedAccessibilityValue(at: startedAt.addingTimeInterval(65)),
            "01:05"
        )

        model.setPaused(true, at: startedAt.addingTimeInterval(65))
        XCTAssertEqual(model.pauseActionTitle, "继续录制")
        XCTAssertEqual(model.recordingStateTitle, "已暂停")
        model.capturesSystemAudio = false
        XCTAssertEqual(model.systemAudioAccessibilityValue, "已关闭")

        _ = model.updateAvailableStorageBytes(512 * 1_024 * 1_024)
        XCTAssertTrue(model.storageAccessibilityValue.contains("不足 1 GB"))
    }

    func testRecordingDetailsNamesOptionalCameraTrackForAccessibility() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/RecordingControlView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".accessibilityLabel(\"摄像头\")"))
        XCTAssertTrue(source.contains(".accessibilityValue(\"单独分轨录制中\")"))
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

    func testDiscardAndRestartIsBlockedDuringRecordingTransitions() {
        let controller = RecordingControlWindowController()
        var requestCount = 0
        controller.onDiscardAndRestart = { requestCount += 1 }

        controller.setTransitioning(true)
        controller.requestDiscardAndRestart()
        XCTAssertEqual(requestCount, 0)

        controller.setTransitioning(false)
        controller.requestDiscardAndRestart()
        XCTAssertEqual(requestCount, 1)
    }

    func testControlPanelStaysAvailableAcrossAppsSpacesAndFullScreen() {
        let controller = RecordingControlWindowController()
        let panel = controller.panelForTesting

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.worksWhenModal)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
    }

    func testManualHideKeepsTheRecordingActionSeparate() {
        let controller = RecordingControlWindowController()
        var hideCount = 0
        var stopCount = 0
        controller.onHide = { hideCount += 1 }
        controller.onStop = { stopCount += 1 }

        controller.requestHide()

        XCTAssertEqual(hideCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertFalse(controller.isVisible)
    }
}
