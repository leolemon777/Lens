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
}
