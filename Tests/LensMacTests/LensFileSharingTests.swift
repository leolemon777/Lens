import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class LensFileSharingTests: XCTestCase {
    private func makeLens() -> SavedLens {
        let packageURL = URL(fileURLWithPath: "/tmp/share-policy.lens")
        let manifest = LensManifest(
            kind: .recording,
            title: "share policy",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [
                LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                LensAsset(role: .renderedVideo, relativePath: "previews/auto.mp4")
            ]
        )
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: manifest
        )
    }

    func testVerifiedRenderIsAnExplicitFirstChoice() {
        let lens = makeLens()
        let renderedURL = lens.packageURL.appendingPathComponent("previews/auto.mp4")
        let existing: Set<URL> = [lens.packageURL, lens.rawAssetURL, renderedURL]

        let choices = LensFileSharing.shareChoices(
            for: lens,
            renderedURL: renderedURL,
            fileExists: { existing.contains($0) }
        )

        XCTAssertEqual(
            choices.map(\.kind),
            [.renderedVideo, .rawRecording, .lensProject]
        )
        XCTAssertEqual(choices.first?.title, "分享成片")
        XCTAssertEqual(choices.first?.url, renderedURL)
    }

    func testUnverifiedRenderIsNotPresentedAsFinishedVideo() {
        let lens = makeLens()
        let existing: Set<URL> = [lens.packageURL, lens.rawAssetURL]

        let choices = LensFileSharing.shareChoices(
            for: lens,
            renderedURL: nil,
            fileExists: { existing.contains($0) }
        )

        XCTAssertEqual(choices.map(\.kind), [.rawRecording, .lensProject])
        XCTAssertFalse(choices.contains { $0.kind == .renderedVideo })
    }

    func testMissingRepresentationsAreOmitted() {
        let lens = makeLens()
        let choices = LensFileSharing.shareChoices(
            for: lens,
            renderedURL: lens.packageURL.appendingPathComponent("previews/auto.mp4"),
            fileExists: { _ in false }
        )

        XCTAssertTrue(choices.isEmpty)
    }
}
