import AppKit
import LensCore
import SwiftUI
import XCTest
@testable import LensMac

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
        XCTAssertTrue(ActionCenterAction.allCases.contains(.conversationInbox))
        XCTAssertEqual(ActionCenterAction.conversationInbox.title, "截到对话")
        XCTAssertEqual(ActionCenterAction.regionRecording.menuTitle, "快速录制区域")
        XCTAssertEqual(ActionCenterAction.openSettings.menuTitle, "设置与权限")
        XCTAssertEqual(ActionCenterAction.ocr.subtitle, "改完再复制")
        XCTAssertTrue(CaptureOverlayAction.conversationInbox.regionGuidance.contains("复制路径"))
        XCTAssertTrue(CaptureOverlayAction.ocr.regionGuidance.contains("可改再复制"))
        XCTAssertFalse(CaptureOverlayAction.ocr.regionGuidance.contains("复制路径"))
        XCTAssertEqual(ActionCenterAction.screenshot.subtitle, "松手就已复制")
        XCTAssertEqual(ActionCenterAction.recordingSetup.subtitle, "停下就能拖走")
    }

    func testPrimaryActionTilesExposeExplicitAccessibilitySemantics() {
        XCTAssertEqual(
            ActionCenterAction.recordingSetup.accessibilityHint,
            "打开录屏设置，选择来源、音频和摄像头"
        )
        XCTAssertEqual(
            ActionCenterAction.screenshot.accessibilityHint,
            "选择截图方式并开始捕获"
        )
        XCTAssertEqual(ActionCenterAction.recordingSetup.title, "录屏")
        XCTAssertEqual(ActionCenterAction.recordingSetup.subtitle, "停下就能拖走")
    }

    func testActionCenterKeepsTwoPrimaryActionsAndExplainsMissingHotKeys() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/ActionCenterView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("actionTile(.recordingSetup"))
        XCTAssertTrue(source.contains("moreMenu"))
        XCTAssertTrue(source.contains("快捷键还不能用"))
        XCTAssertTrue(source.contains("Command-Q 退出"))
        XCTAssertTrue(source.contains("打开最近记录"))
        XCTAssertTrue(source.contains(".accessibilityValue(action.subtitle)"))
        XCTAssertTrue(source.contains(".accessibilityHint(action.accessibilityHint)"))
        XCTAssertFalse(source.contains("内测版 A"))
        XCTAssertFalse(source.contains("actionTile(.ocr"))
        XCTAssertFalse(source.contains("actionTile(.pin"))
    }

    func testRecordingSetupRendersAllVisibleProductControlsWithCameraOff() throws {
        let suiteName = "LensRecordingSetupTests-\(UUID().uuidString)"
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
            "LENS_RECORDING_SETUP_SNAPSHOT"
        ] {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertFalse(model.capturesCamera)
        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 780)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 660)
        XCTAssertGreaterThan(png.count, 28_000)
    }

    func testRecordingSetupStartActionExplainsSelectedSourceAndTracks() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/RecordingSetupView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".accessibilityValue(trackSummary)"))
        XCTAssertTrue(source.contains(".accessibilityHint(startButtonHint)"))
        XCTAssertTrue(source.contains("先在上方选择一个窗口"))
        XCTAssertTrue(source.contains("按下后以当前来源和音轨设置开始录制"))
    }

    func testCaptureOverlayExplainsScreenshotAndRecordingIntentsSeparately() {
        XCTAssertTrue(CaptureOverlayAction.screenshot.windowGuidance.contains("截取"))
        XCTAssertTrue(CaptureOverlayAction.recording.windowGuidance.contains("开始录制"))
        XCTAssertTrue(CaptureOverlayAction.recording.regionGuidance.contains("录制区域"))
        XCTAssertTrue(CaptureOverlayAction.scrollingCapture.regionGuidance.contains("滚动内容"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("方向键微调"))
        XCTAssertTrue(CaptureOverlayAction.screenshot.regionGuidance.contains("Option 暂停吸附"))
        XCTAssertTrue(CaptureOverlayAction.conversationInbox.regionGuidance.contains("复制路径"))
        XCTAssertTrue(CaptureOverlayAction.ocr.regionGuidance.contains("可改再复制"))
        XCTAssertTrue(CaptureOverlayAction.ocr.regionGuidance.contains("识别"))
    }

    func testAccessoryApplicationMenuProvidesStandardCommandQQuitItem() throws {
        let target = ApplicationMenuTarget()
        let mainMenu = AppDelegate.makeApplicationMainMenu(target: target)
        let applicationMenu = try XCTUnwrap(mainMenu.items.first?.submenu)
        let quitItem = try XCTUnwrap(applicationMenu.items.first {
            $0.action == #selector(ApplicationMenuTarget.quit)
        })

        XCTAssertEqual(quitItem.title, "退出 Lens")
        XCTAssertEqual(quitItem.keyEquivalent, "q")
        XCTAssertEqual(quitItem.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quitItem.target === target)

        let editMenu = try XCTUnwrap(
            mainMenu.items.first { $0.title == "编辑" }?.submenu
        )
        let copyItem = try XCTUnwrap(editMenu.items.first { $0.title == "复制" })
        XCTAssertEqual(copyItem.keyEquivalent, "c")
        XCTAssertEqual(copyItem.action, #selector(NSText.copy(_:)))
        XCTAssertNil(copyItem.target)
        XCTAssertTrue(editMenu.items.contains { $0.action == Selector(("undo:")) })
        XCTAssertTrue(editMenu.items.contains { $0.action == #selector(NSText.paste(_:)) })
        XCTAssertTrue(editMenu.items.contains { $0.action == #selector(NSText.selectAll(_:)) })
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
            "LENS_ACTION_CENTER_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 688)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 430)
        XCTAssertGreaterThan(png?.count ?? 0, 18_000)
    }

    func testGlassSystemUsesOneMaterialLayerAndAccessibleMotion() {
        XCTAssertTrue(LensGlassSurfaceRole.window.usesBackdropMaterial)
        XCTAssertTrue(LensGlassSurfaceRole.panel.usesBackdropMaterial)
        XCTAssertTrue(LensGlassSurfaceRole.chrome.usesBackdropMaterial)
        XCTAssertFalse(LensGlassSurfaceRole.card.usesBackdropMaterial)
        XCTAssertFalse(LensGlassSurfaceRole.control.usesBackdropMaterial)
        XCTAssertEqual(
            LensMotionPolicy.interactiveScale(
                isPressed: false,
                isHovering: true,
                reduceMotion: true
            ),
            1
        )
        XCTAssertEqual(
            LensMotionPolicy.hoverOffset(isHovering: true, reduceMotion: true),
            0
        )
        XCTAssertNil(LensMotionPolicy.panelAnimation(reduceMotion: true))
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
            .lensAccessibilityOverrides(reduceTransparency: true, reduceMotion: true)
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
            LensMotionPolicy.pressedScale(isPressed: true, reduceMotion: true),
            1
        )
        XCTAssertNil(LensMotionPolicy.buttonAnimation(reduceMotion: true))
        XCTAssertNil(LensMotionPolicy.meterAnimation(reduceMotion: true))
    }
}
