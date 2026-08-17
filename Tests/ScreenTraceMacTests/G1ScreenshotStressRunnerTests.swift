import Foundation
import XCTest
@testable import ScreenTraceMac

final class G1ScreenshotStressRunnerTests: XCTestCase {
    func testConfigurationUsesReleaseGateDefaults() throws {
        let configuration = try XCTUnwrap(
            G1ScreenshotStressConfiguration(
                arguments: ["ScreenTrace", "--g1-screenshot-stress"]
            )
        )

        XCTAssertEqual(configuration.iterations, 100)
        XCTAssertTrue(
            configuration.reportURL.path.hasSuffix(
                "/Build/Quality/g1-screenshot-stress-latest.json"
            )
        )
    }

    func testConfigurationClampsIterationsAndResolvesRequestedReport() throws {
        let configuration = try XCTUnwrap(
            G1ScreenshotStressConfiguration(
                arguments: [
                    "ScreenTrace",
                    "--g1-screenshot-stress",
                    "--iterations", "5000",
                    "--report", "Build/Quality/custom-g1.json"
                ]
            )
        )

        XCTAssertEqual(configuration.iterations, 1_000)
        XCTAssertTrue(configuration.reportURL.isFileURL)
        XCTAssertTrue(configuration.reportURL.path.hasSuffix("/Build/Quality/custom-g1.json"))
    }

    func testConfigurationIgnoresOrdinaryApplicationLaunch() {
        XCTAssertNil(G1ScreenshotStressConfiguration(arguments: ["ScreenTrace"]))
    }
}
