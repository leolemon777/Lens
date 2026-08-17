import AVFoundation
import Speech
import XCTest
@testable import ScreenTraceMac

final class PermissionCenterModelTests: XCTestCase {
    @MainActor
    func testSpeechAuthorizationCallbackCanEnterFromBackgroundExecutor() async {
        let refreshed = expectation(description: "refresh returned to main actor")
        let callback = PermissionCenterModel.speechAuthorizationCallback {
            MainActor.assertIsolated()
            refreshed.fulfill()
        }

        await Task.detached {
            callback(.authorized)
        }.value
        await fulfillment(of: [refreshed], timeout: 1)
    }

    @MainActor
    func testDiagnosticSummaryCopyReportsSuccessWithoutChangingItsContents() async {
        let copied = expectation(description: "diagnostic summary copied")
        var receivedSummary: String?
        let model = PermissionCenterModel(
            diagnosticSummaryProvider: { "safe diagnostic summary" },
            diagnosticSummaryConsumer: { summary in
                receivedSummary = summary
                copied.fulfill()
                return true
            }
        )

        model.copyDiagnosticSummary()
        await fulfillment(of: [copied], timeout: 1)

        XCTAssertEqual(receivedSummary, "safe diagnostic summary")
        XCTAssertEqual(model.diagnosticStatusMessage, "诊断摘要已复制")
        XCTAssertFalse(model.isPreparingDiagnosticSummary)
    }

    func testAVAuthorizationStatusMapsToPermissionPresentation() {
        XCTAssertEqual(
            PermissionAccessState(authorizationStatus: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            PermissionAccessState(authorizationStatus: .authorized),
            .granted
        )
        XCTAssertEqual(
            PermissionAccessState(authorizationStatus: .denied),
            .denied
        )
        XCTAssertEqual(
            PermissionAccessState(authorizationStatus: .restricted),
            .restricted
        )
    }

    func testGrantedPermissionNeedsNoPrimaryAction() {
        XCTAssertNil(PermissionAccessState.granted.primaryActionTitle)
        XCTAssertEqual(PermissionAccessState.notDetermined.primaryActionTitle, "允许")
        XCTAssertEqual(PermissionAccessState.denied.primaryActionTitle, "打开设置")
        XCTAssertEqual(PermissionAccessState.restricted.primaryActionTitle, "打开设置")
    }

    func testSpeechAuthorizationStatusMapsToPermissionPresentation() {
        XCTAssertEqual(
            PermissionAccessState(speechAuthorizationStatus: .notDetermined),
            .notDetermined
        )
        XCTAssertEqual(
            PermissionAccessState(speechAuthorizationStatus: .authorized),
            .granted
        )
        XCTAssertEqual(
            PermissionAccessState(speechAuthorizationStatus: .denied),
            .denied
        )
        XCTAssertEqual(
            PermissionAccessState(speechAuthorizationStatus: .restricted),
            .restricted
        )
    }

    func testPermissionKindsRemainCompleteAndOrdered() {
        XCTAssertEqual(
            SystemPermissionKind.allCases.map(\.rawValue),
            [
                "screenCapture",
                "microphone",
                "camera",
                "speechRecognition",
                "inputMonitoring",
                "accessibility"
            ]
        )
    }
}
