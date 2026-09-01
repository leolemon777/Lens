import XCTest
@testable import LensMac

final class G4AccessibilityHostRunnerTests: XCTestCase {
    func testConfigurationRequiresHostModeAndReadyMarker() throws {
        XCTAssertNil(G4AccessibilityHostConfiguration(arguments: ["Lens"]))
        XCTAssertNil(G4AccessibilityHostConfiguration(arguments: [
            "Lens", "--g4-accessibility-host"
        ]))
        let configuration = try XCTUnwrap(G4AccessibilityHostConfiguration(arguments: [
            "Lens",
            "--g4-accessibility-host",
            "--ready-marker",
            "/tmp/lens-g4-ready"
        ]))
        XCTAssertEqual(configuration.readyMarkerURL.path, "/tmp/lens-g4-ready")
    }

    func testAccessibilityHostIncludesRecordingControlActions() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LensMac/Support/G4AccessibilityHostRunner.swift"),
            encoding: .utf8
        )
        let audit = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Scripts/g4-accessibility-audit.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("G4 录制浮标无障碍验收"))
        XCTAssertTrue(source.contains("capturesCamera: true"))
        XCTAssertTrue(audit.contains("录制详情"))
        XCTAssertTrue(audit.contains("隐藏录屏浮标"))
        XCTAssertTrue(audit.contains("暂停录制"))
        XCTAssertTrue(audit.contains("停止录制"))
        XCTAssertTrue(source.contains("G4 Lens 库无障碍验收"))
        XCTAssertTrue(source.contains("libraryModel.query = \"视频\""))
        XCTAssertTrue(audit.contains("搜索 Lens 库"))
        XCTAssertTrue(audit.contains("复制文件"))
        XCTAssertTrue(audit.contains("分享"))
        XCTAssertTrue(audit.contains("刷新 Lens 库"))
    }
}
