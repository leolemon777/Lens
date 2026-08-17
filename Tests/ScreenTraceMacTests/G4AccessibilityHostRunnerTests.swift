import XCTest
@testable import ScreenTraceMac

final class G4AccessibilityHostRunnerTests: XCTestCase {
    func testConfigurationRequiresHostModeAndReadyMarker() throws {
        XCTAssertNil(G4AccessibilityHostConfiguration(arguments: ["ScreenTrace"]))
        XCTAssertNil(G4AccessibilityHostConfiguration(arguments: [
            "ScreenTrace", "--g4-accessibility-host"
        ]))
        let configuration = try XCTUnwrap(G4AccessibilityHostConfiguration(arguments: [
            "ScreenTrace",
            "--g4-accessibility-host",
            "--ready-marker",
            "/tmp/screentrace-g4-ready"
        ]))
        XCTAssertEqual(configuration.readyMarkerURL.path, "/tmp/screentrace-g4-ready")
    }
}
