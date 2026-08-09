import AVFoundation
import Speech
import XCTest
@testable import ScreenTraceMac

final class PermissionCenterModelTests: XCTestCase {
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
            ["screenCapture", "microphone", "camera", "speechRecognition", "accessibility"]
        )
    }
}
