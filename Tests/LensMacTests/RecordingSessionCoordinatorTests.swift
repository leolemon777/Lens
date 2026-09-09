import XCTest
import LensCore
@testable import LensMac

@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    func testStartStopAndFailedStopRestoreTheExplicitPhase() {
        let coordinator = RecordingSessionCoordinator()
        XCTAssertTrue(coordinator.isIdle)
        XCTAssertTrue(coordinator.beginStart())
        XCTAssertFalse(coordinator.beginStart())
        coordinator.markRecording()
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertFalse(coordinator.beginStart())
        XCTAssertTrue(coordinator.beginStop())
        XCTAssertTrue(coordinator.isStopping)
        XCTAssertFalse(coordinator.beginStop())
        coordinator.abortStop()
        XCTAssertTrue(coordinator.isRecording)
        XCTAssertTrue(coordinator.beginStop())
        coordinator.markIdle()
        XCTAssertTrue(coordinator.isIdle)
    }

    func testCancelStartOnlyResetsWhileStillStarting() {
        let coordinator = RecordingSessionCoordinator()
        XCTAssertTrue(coordinator.beginStart())
        coordinator.cancelStart()
        XCTAssertTrue(coordinator.isIdle)
        XCTAssertTrue(coordinator.beginStart())
        coordinator.markRecording()
        coordinator.cancelStart()
        XCTAssertTrue(coordinator.isRecording)
    }

    func testCoordinatorOwnsStorageMonitorAcrossControlFloatTeardown() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/Capture/RecordingSessionCoordinator.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("storageMonitor.start(storageURL:"))
        XCTAssertTrue(source.contains("endControlSession()"))
        XCTAssertTrue(source.contains("storageMonitor.stop()"))
        XCTAssertTrue(source.contains("stopForCriticalStorage"))
        XCTAssertTrue(source.contains("automaticZoomScale: model.automaticCameraZoomScale"))
        XCTAssertFalse(source.contains("recordingControl.onCriticalStorage"))
    }

    func testStartPlanUsesExplicitCameraAndAudioSummary() {
        let source = RecordingCaptureSource(
            mode: .display,
            displayID: 1,
            captureBounds: CGRect(x: 0, y: 0, width: 1_280, height: 800)
        )
        let plan = RecordingSessionCoordinator.startPlan(
            source: source,
            capturesCamera: true,
            experiencePreset: .teaching,
            framesPerSecond: 60,
            capturesSystemAudio: true,
            capturesMicrophone: true
        )
        XCTAssertEqual(plan.sourceTitle, "屏幕录制")
        XCTAssertEqual(plan.experienceTitle, "教学讲解")
        XCTAssertEqual(plan.audioSummary, "系统声音 + 麦克风分轨")
        XCTAssertTrue(plan.capturesCamera)
        XCTAssertEqual(plan.toastTitle, "正在准备屏幕录制")
        XCTAssertTrue(plan.toastDetail.contains("摄像头分轨"))
        XCTAssertEqual(
            RecordingSessionCoordinator.startPlan(
                source: source,
                capturesCamera: false,
                experiencePreset: .source,
                framesPerSecond: 30,
                capturesSystemAudio: false,
                capturesMicrophone: false
            ).audioSummary,
            "无音频"
        )
    }
}
