import AppKit
import ScreenTraceCore
import SwiftUI
import XCTest
@testable import ScreenTraceMac

private final class ApplicationMenuTarget: NSObject {
    @objc func quit() {}
}

@MainActor
final class ActionCenterViewTests: XCTestCase {
    func testWindowPickerRequiresExplicitSelectionAndKeepsExactWindowSource() {
        let candidate = WindowSelectionCandidate(
            id: 482,
            globalFrame: CGRect(x: 120, y: 80, width: 1_280, height: 720),
            frontToBackOrder: 3,
            title: "Safari 长截图测试",
            applicationName: "Safari"
        )
        let source = CaptureGeometry.windowRecordingSource(candidate)
        let picker = RecordingWindowPickerModel(previewOptions: [
            RecordingWindowOption(
                id: candidate.id,
                source: source,
                applicationName: candidate.applicationName,
                windowTitle: candidate.title
            )
        ])

        XCTAssertNil(picker.selectedSource)
        picker.selectWindow(id: 999)
        XCTAssertNil(picker.selectedSource)
        picker.selectWindow(id: candidate.id)
        XCTAssertEqual(picker.selectedSource, source)
    }

    func testActionRoutingIncludesAllThreeRecordingSources() {
        XCTAssertTrue(ActionCenterAction.allCases.contains(.regionRecording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.windowRecording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.recording))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.recordingSetup))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.scrollingCapture))
        XCTAssertTrue(ActionCenterAction.allCases.contains(.multiWindowScreenshot))
    }

    func testRecordingSetupRendersAllVisibleProductControlsWithCameraOff() throws {
        let suiteName = "ScreenTraceRecordingSetupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "recording.capturesCamera")
        let model = AppModel(defaults: defaults)
        let root = ZStack {
            Color(red: 0.42, green: 0.45, blue: 0.50)
            RecordingSetupView(model: model, onStart: { _ in }, onClose: {})
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 780, height: 660)
        let snapshotWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.contentView = hostingView
        snapshotWindow.setFrameOrigin(NSPoint(x: -2_000, y: -2_000))
        snapshotWindow.orderFront(nil)
        defer { snapshotWindow.orderOut(nil) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        if let snapshotPath = ProcessInfo.processInfo.environment[
            "SCREENTRACE_RECORDING_SETUP_SNAPSHOT"
        ] {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertFalse(model.capturesCamera)
        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 780)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 660)
        XCTAssertGreaterThan(png.count, 28_000)
    }

    func testCaptureOverlayExplainsScreenshotAndRecordingIntentsSeparately() {
        XCTAssertTrue(CaptureOverlayAction.screenshot.windowGuidance.contains("截取"))
        XCTAssertTrue(CaptureOverlayAction.recording.windowGuidance.contains("开始录制"))
        XCTAssertTrue(CaptureOverlayAction.recording.regionGuidance.contains("录制区域"))
        XCTAssertTrue(CaptureOverlayAction.scrollingCapture.regionGuidance.contains("滚动内容"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("方向键微调"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("Option 暂停吸附"))
    }

    func testAccessoryApplicationMenuProvidesStandardCommandQQuitItem() throws {
        let target = ApplicationMenuTarget()
        let mainMenu = AppDelegate.makeApplicationMainMenu(target: target)
        let applicationMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let quitItem = try XCTUnwrap(applicationMenu.items.first {
            $0.action == #selector(ApplicationMenuTarget.quit)
        })

        XCTAssertEqual(quitItem.title, "退出屏迹")
        XCTAssertEqual(quitItem.keyEquivalent, "q")
        XCTAssertEqual(quitItem.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quitItem.target === target)
    }

    func testActionCenterRendersRecordingAndScreenshotMenusAtPanelSize() throws {
        let root = ZStack {
            Color(red: 0.42, green: 0.45, blue: 0.50)
            ActionCenterView(model: AppModel()) { _ in }
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 688, height: 430)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create Action Center snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])
        if let snapshotPath = ProcessInfo.processInfo.environment[
            "SCREENTRACE_ACTION_CENTER_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 688)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 430)
        XCTAssertGreaterThan(png?.count ?? 0, 18_000)
    }

    func testGlassSystemUsesOneMaterialLayerAndAccessibleMotion() {
        XCTAssertTrue(TraceGlassSurfaceRole.window.usesBackdropMaterial)
        XCTAssertTrue(TraceGlassSurfaceRole.panel.usesBackdropMaterial)
        XCTAssertTrue(TraceGlassSurfaceRole.chrome.usesBackdropMaterial)
        XCTAssertFalse(TraceGlassSurfaceRole.card.usesBackdropMaterial)
        XCTAssertFalse(TraceGlassSurfaceRole.control.usesBackdropMaterial)
        XCTAssertEqual(
            TraceMotionPolicy.interactiveScale(
                isPressed: false,
                isHovering: true,
                reduceMotion: true
            ),
            1
        )
        XCTAssertEqual(
            TraceMotionPolicy.hoverOffset(isHovering: true, reduceMotion: true),
            0
        )
        XCTAssertNil(TraceMotionPolicy.panelAnimation(reduceMotion: true))
    }

    func testActionCenterRendersDarkHighContrastAppearanceVariant() throws {
        let root = ActionCenterView(model: AppModel()) { _ in }
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        hostingView.frame = CGRect(x: 0, y: 0, width: 688, height: 430)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 688)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 430)
        XCTAssertGreaterThan(png.count, 18_000)
    }

    func testActionCenterRendersWithReducedTransparencyAndMotion() throws {
        let root = ActionCenterView(model: AppModel()) { _ in }
            .traceAccessibilityOverrides(reduceTransparency: true, reduceMotion: true)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 688, height: 430)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 688)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 430)
        XCTAssertGreaterThan(png.count, 18_000)
        XCTAssertEqual(
            TraceMotionPolicy.pressedScale(isPressed: true, reduceMotion: true),
            1
        )
        XCTAssertNil(TraceMotionPolicy.buttonAnimation(reduceMotion: true))
        XCTAssertNil(TraceMotionPolicy.meterAnimation(reduceMotion: true))
    }
}
