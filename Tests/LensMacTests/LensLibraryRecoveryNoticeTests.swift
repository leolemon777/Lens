import AppKit
import SwiftUI
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class LensLibraryRecoveryNoticeTests: XCTestCase {
    private func makeLibrary(
        findings: [RecordingRecoveryAssessment.Finding],
        presented: Double,
        available: Double
    ) throws -> (Data, LensLibraryEntry) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecoveryNotice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let package = root.appendingPathComponent("recording.lens")
        let asset = root.appendingPathComponent("recording.mp4")
        let entry = LensLibraryEntry(
            packageURL: package,
            manifest: LensManifest(
                id: UUID(),
                kind: .recording,
                createdAt: Date(),
                title: "会议演示录屏",
                state: .ready,
                dimensions: LensDimensions(width: 1_920, height: 1_080),
                assets: []
            ),
            primaryAssetURL: asset,
            displayAssetURL: asset,
            ocrText: nil
        )
        let assessment = RecordingRecoveryAssessment(
            findings: findings,
            presentedScreenSeconds: presented,
            availableScreenSeconds: available
        )
        let model = LensLibraryModel(
            store: LensProjectStore(rootDirectory: root),
            initialEntries: [entry],
            initialRecoveryFindings: [entry.id: assessment]
        )
        let rootView = LensLibraryView(
            model: model,
            onOpen: { _ in },
            onReveal: { _ in },
            onCopy: { _ in },
            onAnnotate: { _ in },
            onShowOCR: { _ in },
            onTranscribe: { _ in },
            onOrganize: { _ in },
            onSaveInsights: { _, _ in },
            onDelete: { _ in },
            onRepair: { _ in },
            onDeleteAll: {},
            onOpenFolder: {},
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(x: 0, y: 0, width: 1_020, height: 690)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -3_000, y: -3_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        if let directory = ProcessInfo.processInfo.environment[
            "LENS_RECOVERY_SNAPSHOT_DIRECTORY"
        ] {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory),
                withIntermediateDirectories: true
            )
            try png.write(
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("recovery-\(findings.count)-\(Int(available)).png"),
                options: .atomic
            )
        }
        return (png, entry)
    }

    func testRebuildableRecordingRendersDifferentlyFromADeadScreenStream() throws {
        // A recording that holds more picture offers a rebuild. One whose
        // screen stream died has nothing left to merge, so it must not.
        let (rebuildable, _) = try makeLibrary(
            findings: [.unindexedScreenSegment(index: 1, seconds: 9.213)],
            presented: 3.143,
            available: 12.356
        )
        let (deadStream, _) = try makeLibrary(
            findings: [
                .sideTrackOutlivesScreen(
                    role: .microphone,
                    relativePath: "raw/microphone.caf",
                    screenSeconds: 10.085,
                    trackSeconds: 46.9
                )
            ],
            presented: 10.085,
            available: 10.085
        )

        XCTAssertGreaterThan(rebuildable.count, 25_000)
        XCTAssertGreaterThan(deadStream.count, 25_000)
        XCTAssertNotEqual(rebuildable, deadStream)
    }

    func testAHealthyLibraryShowsNoRecoveryBand() throws {
        let (damaged, _) = try makeLibrary(
            findings: [.unindexedScreenSegment(index: 1, seconds: 9.213)],
            presented: 3.143,
            available: 12.356
        )
        let (healthy, _) = try makeLibrary(
            findings: [],
            presented: 12.356,
            available: 12.356
        )

        XCTAssertNotEqual(damaged, healthy)
    }
}
