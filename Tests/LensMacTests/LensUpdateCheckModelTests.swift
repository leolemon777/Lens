import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
private final class LensUpdateActivityStateBox {
    var value = LensUpdateActivityState()
}

@MainActor
final class LensUpdateCheckModelTests: XCTestCase {
    func testUnconfiguredManualCheckNeverStartsNetworking() async {
        var operationCalled = false
        let model = LensUpdateCheckModel { 
            operationCalled = true
            return .upToDate
        }

        await model.checkForUpdates()

        XCTAssertFalse(operationCalled)
        XCTAssertEqual(
            model.status,
            .failed(message: "当前构建尚未配置更新源，未发起联网请求。")
        )
    }

    func testAvailableUpdateIsReviewableAndExposesHTTPSDownloadPage() async {
        let manifest = LensUpdateManifest(
            channel: "dev",
            version: "0.2.0",
            build: "20260908010000",
            downloadURL: "https://updates.example.test/lens.dmg",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "AA=="
        )
        let model = LensUpdateCheckModel(configured: true) {
            .available(manifest)
        }

        await model.checkForUpdates()

        XCTAssertEqual(
            model.status,
            .available(
                version: "0.2.0",
                build: "20260908010000",
                downloadURL: "https://updates.example.test/lens.dmg"
            )
        )
        XCTAssertEqual(
            model.availableDownloadURL?.absoluteString,
            "https://updates.example.test/lens.dmg"
        )
        XCTAssertEqual(
            model.statusMessage,
            "发现新版本 0.2.0（20260908010000），请打开下载页手动安装。"
        )
    }

    func testOfflineFailureDoesNotSuggestInstallMutation() async {
        let model = LensUpdateCheckModel(configured: true) {
            .failed(.transport)
        }

        await model.checkForUpdates()

        XCTAssertEqual(
            model.status,
            .failed(message: "无法连接更新服务，当前版本保持不变。")
        )
        XCTAssertNil(model.availableDownloadURL)
    }

    func testHostlessHTTPSUpdateDoesNotExposeDownloadAction() async {
        let manifest = LensUpdateManifest(
            channel: "dev",
            version: "0.2.0",
            build: "20260908010000",
            downloadURL: "https:/lens.dmg",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "AA=="
        )
        let model = LensUpdateCheckModel(configured: true) {
            .available(manifest)
        }

        await model.checkForUpdates()

        XCTAssertNil(model.availableDownloadURL)
        XCTAssertFalse(model.canReplaceCurrentInstall)
    }

    func testActivityStateBlocksReplacementWithoutHidingManualDownloadPage() async {
        let manifest = LensUpdateManifest(
            channel: "dev",
            version: "0.2.0",
            build: "20260908010000",
            downloadURL: "https://updates.example.test/lens.dmg",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "AA=="
        )
        let model = LensUpdateCheckModel(configured: true) {
            .available(manifest)
        }

        await model.checkForUpdates()
        model.setActivityState(LensUpdateActivityState(isRendering: true))

        XCTAssertNotNil(model.availableDownloadURL)
        XCTAssertFalse(model.canReplaceCurrentInstall)
        XCTAssertEqual(
            model.installationBlockMessage,
            "正在生成成片，完成处理后才能替换当前安装。"
        )
    }

    func testIdleActivityAllowsReplacementOnlyForAnAvailableHTTPSUpdate() async {
        let manifest = LensUpdateManifest(
            channel: "dev",
            version: "0.2.0",
            build: "20260908010000",
            downloadURL: "https://updates.example.test/lens.dmg",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "AA=="
        )
        let model = LensUpdateCheckModel(configured: true) {
            .available(manifest)
        }

        XCTAssertFalse(model.canReplaceCurrentInstall)
        await model.checkForUpdates()
        XCTAssertTrue(model.canReplaceCurrentInstall)

        model.setActivityState(LensUpdateActivityState(hasUnsavedEdits: true))
        XCTAssertFalse(model.canReplaceCurrentInstall)
        XCTAssertEqual(
            model.installationBlockMessage,
            "存在未保存编辑，保存后才能替换当前安装。"
        )
    }

    func testLiveActivityProviderIsConsultedAtReplacementBoundary() async {
        let manifest = LensUpdateManifest(
            channel: "dev",
            version: "0.2.0",
            build: "20260908010000",
            downloadURL: "https://updates.example.test/lens.dmg",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "AA=="
        )
        let activityBox = LensUpdateActivityStateBox()
        let model = LensUpdateCheckModel(
            configured: true,
            check: { .available(manifest) },
            activityStateProvider: { activityBox.value }
        )

        await model.checkForUpdates()
        XCTAssertTrue(model.canReplaceCurrentInstall)

        activityBox.value = LensUpdateActivityState(isRecording: true)
        XCTAssertFalse(model.canReplaceCurrentInstall)
        XCTAssertEqual(
            model.installationBlockMessage,
            "录制进行中，完成录制后才能替换当前安装。"
        )

        activityBox.value = LensUpdateActivityState()
        XCTAssertTrue(model.canReplaceCurrentInstall)
    }
}
