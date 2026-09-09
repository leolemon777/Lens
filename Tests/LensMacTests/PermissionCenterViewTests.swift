import AppKit
import SwiftUI
import XCTest
@testable import LensMac

@MainActor
final class PermissionCenterViewTests: XCTestCase {
    func testPermissionRowsExposeStateAndTargetedActionLabels() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/PermissionCenterView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("权限状态"))
        XCTAssertTrue(source.contains("录屏偏好"))
        XCTAssertTrue(source.contains("素材库存储"))
        XCTAssertTrue(source.contains("管理 Lens 素材库存储"))
        XCTAssertTrue(source.contains("当前素材库根目录"))
        XCTAssertTrue(source.contains("appModel.lensStorageRootDirectory"))
        XCTAssertTrue(source.contains("迁移会先复制并校验"))
        XCTAssertTrue(source.contains("storageMigrationProgress"))
        XCTAssertTrue(source.contains("storageMigrationPhaseTitle"))
        XCTAssertTrue(source.contains("取消迁移"))
        XCTAssertTrue(source.contains("onCancelStorageMigration"))
        XCTAssertTrue(source.contains("AutomaticCameraZoomPreferenceCard"))
        XCTAssertTrue(source.contains("automaticCameraZoomScale"))
        XCTAssertTrue(source.contains("检查更新"))
        XCTAssertTrue(source.contains("自动检查更新（尚未开放）"))
        XCTAssertTrue(source.contains("未配置可信更新源"))
        XCTAssertTrue(source.contains("打开下载页"))
        XCTAssertTrue(source.contains("installationBlockMessage"))
        XCTAssertTrue(source.contains("updateModel.checkForUpdates()"))
        let cardIndex = try XCTUnwrap(source.range(of: "AutomaticCameraZoomPreferenceCard")?.lowerBound)
        let scrollIndex = try XCTUnwrap(source.range(of: "ScrollView")?.lowerBound)
        XCTAssertLessThan(
            cardIndex,
            scrollIndex,
            "运镜卡片必须钉在设置窗口顶部，打开就能看见，不能藏在快捷键下面"
        )
        XCTAssertTrue(source.contains("停止录制"))
        XCTAssertTrue(source.contains("\\(actionTitle)：\\(kind.title)"))
        XCTAssertTrue(source.contains("请求\\(kind.title)权限"))
        XCTAssertTrue(source.contains("打开系统设置中的\\(kind.title)权限"))

        let card = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/UI/AutomaticCameraZoomPreferenceCard.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(card.contains("自动运镜推近"))
        XCTAssertTrue(card.contains("调节这项"))
        XCTAssertTrue(card.contains("成片默认"))
        XCTAssertTrue(card.contains("点击后镜头放大画面的程度"))
    }

    func testUpdateInstallGateReceivesLiveActivityState() throws {
        let controller = try sourceText(at: "Sources/LensMac/UI/PermissionCenterWindowController.swift")
        let appDelegate = try sourceText(at: "Sources/LensMac/AppDelegate.swift")
        let editor = try sourceText(at: "Sources/LensMac/UI/VideoEditorWindowController.swift")

        XCTAssertTrue(controller.contains("activityStateProvider"))
        XCTAssertTrue(controller.contains("updateModel.bindActivityStateProvider"))
        XCTAssertTrue(controller.contains("updateModel.refreshActivityState"))
        XCTAssertTrue(appDelegate.contains("currentLensUpdateActivityState"))
        XCTAssertTrue(appDelegate.contains("recordingRenderTaskRegistry.activePackageURLs"))
        XCTAssertTrue(editor.contains("var hasUnsavedEdits"))
    }

    func testStorageDialogSeparatesEveryManagedCategory() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/AppDelegate.swift"),
            encoding: .utf8
        )

        for label in ["原始素材", "成片", "派生数据", "索引", "可重建缓存", "可清理临时文件"] {
            XCTAssertTrue(
                source.contains(label),
                "存储管理弹窗必须明确说明 \(label) 的占用"
            )
        }
        XCTAssertTrue(source.contains("bytesByCategory[.derived]"))
        XCTAssertTrue(source.contains("bytesByCategory[.index]"))
        XCTAssertTrue(source.contains("bytesByCategory[.rebuildable]"))
    }

    func testPermissionCenterRendersEditableShortcutsAndPermissions() throws {
        let suiteName = "LensPermissionViewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = ZStack {
            Color(red: 0.55, green: 0.55, blue: 0.55)
            PermissionCenterView(
                model: PermissionCenterModel(),
                appModel: AppModel(defaults: defaults),
                onShortcutsChanged: {},
                onClose: {}
            )
        }
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 678, height: 720)
        hostingView.layoutSubtreeIfNeeded()

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw XCTSkip("Unable to create permission center snapshot")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])
        if let path = ProcessInfo.processInfo.environment[
            "LENS_PERMISSION_CENTER_SNAPSHOT"
        ], let png {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 678)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 628)
        XCTAssertGreaterThan(png?.count ?? 0, 20_000)
    }

    private func sourceText(at relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
