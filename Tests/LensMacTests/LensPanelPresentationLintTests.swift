import XCTest
@testable import LensMac

/// Scans `Sources/LensMac/UI/*WindowController.swift` for bare
/// `orderFrontRegardless()` / `orderOut(nil)` / `makeKeyAndOrderFront(nil)`
/// calls. These hard-cut every floating panel's appearance and disappearance
/// with no transition; the UI polish plan replaces them with
/// `LensPanelPresenter` for panel-style controllers.
///
/// Three groups are permanently exempt because they are not meant to change:
/// - `PinnedImageWindowController` manages its own click-through badge and
///   hover-toolbar fades separately from panel presentation.
/// - `LensLibraryWindowController`, `VideoEditorWindowController` and
///   `ScreenshotAnnotationEditorWindowController` are standard resizable
///   document-style windows, not transient glass panels, and intentionally
///   keep default AppKit show/hide behavior.
/// - `RecordingCountdownWindowController` is a full-screen instant overlay
///   like `CaptureOverlayView`'s capture mask (outside this lint's file
///   pattern): scaling a screen-sized window in/out around an anchor would
///   look like a glitch, not polish.
///
/// Everything else is expected to reach zero raw call sites once each
/// controller is migrated to the presenter; the baseline ratchets down as
/// that migration lands and should never move back up.
@MainActor
final class LensPanelPresentationLintTests: XCTestCase {
    private static let permanentlyExemptFiles: Set<String> = [
        "PinnedImageWindowController.swift",
        "LensLibraryWindowController.swift",
        "VideoEditorWindowController.swift",
        "ScreenshotAnnotationEditorWindowController.swift",
        "RecordingCountdownWindowController.swift"
    ]

    // Ratchet baseline. All nine controllers were migrated to
    // LensPanelPresenter on 2026-08-31 (down from a baseline of 22 raw call
    // sites); this is now a hard zero, not a budget.
    private static let maxRawPresentationCalls = 0

    private static let uiDirectoryURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI")
    }()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let callPattern = regex(
        #"\.orderFrontRegardless\(\)|\.orderOut\(nil\)|\.makeKeyAndOrderFront\(nil\)"#
    )

    private static func targetFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: uiDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix("WindowController.swift") }
        .filter { !permanentlyExemptFiles.contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testRawPresentationCallsStayWithinMigrationBudget() throws {
        var offenders: [String] = []
        var count = 0
        for url in try Self.targetFiles() {
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let matches = Self.callPattern.numberOfMatches(in: line, range: range)
                guard matches > 0 else { continue }
                count += matches
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertLessThanOrEqual(
            count,
            Self.maxRawPresentationCalls,
            """
            Found \(count) raw presentation call(s) outside LensPanelPresenter, \
            baseline allows at most \(Self.maxRawPresentationCalls). Migrate the \
            controller to LensPanelPresenter instead of calling AppKit's raw \
            order(Front|Out) APIs directly. Offending lines:
            \(offenders.prefix(20).joined(separator: "\n"))
            """
        )
    }

    func testExemptFilesAreStillPresentOnDisk() throws {
        // Guards against the whitelist silently going stale if a file is
        // renamed or removed without updating this test.
        let existingNames = Set(
            try FileManager.default.contentsOfDirectory(
                at: Self.uiDirectoryURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        for name in Self.permanentlyExemptFiles {
            XCTAssertTrue(
                existingNames.contains(name),
                "\(name) is whitelisted by name but no longer exists in Sources/LensMac/UI."
            )
        }
    }
}
