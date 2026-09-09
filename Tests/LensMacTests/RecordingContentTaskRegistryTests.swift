import Foundation
import XCTest
@testable import LensMac

@MainActor
final class RecordingContentTaskRegistryTests: XCTestCase {
    func testKindsAreIndependentAndPackagesAreNormalized() {
        let registry = RecordingContentTaskRegistry()
        let package = URL(fileURLWithPath: "/tmp/content/../content/item.lens")

        XCTAssertTrue(registry.begin(packageURL: package, kind: .transcription))
        XCTAssertFalse(registry.begin(packageURL: package, kind: .transcription))
        XCTAssertTrue(registry.begin(packageURL: package, kind: .organization))
        XCTAssertEqual(registry.count(kind: .transcription), 1)
        XCTAssertEqual(registry.count(kind: .organization), 1)
        XCTAssertEqual(registry.activePackageURLs.count, 1)

        registry.finish(packageURL: package, kind: .transcription)
        XCTAssertFalse(registry.contains(packageURL: package, kind: .transcription))
        XCTAssertTrue(registry.contains(packageURL: package, kind: .organization))
    }
}
