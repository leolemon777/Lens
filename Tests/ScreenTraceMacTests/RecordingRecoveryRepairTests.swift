import AVFoundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

@MainActor
final class RecordingRecoveryRepairTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecoveryRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A project that finished while its continuation segment was never given
    /// a duration, which is how a recording ends up presenting a fraction of
    /// the picture it holds.
    private func makeDamagedProject(
        leadingSeconds: Double = 1,
        continuationSeconds: Double = 2
    ) async throws -> URL {
        let fm = FileManager.default
        let package = root.appendingPathComponent("Trace-damaged.screentrace", isDirectory: true)
        for sub in ["raw/segments", "events", "edits"] {
            try fm.createDirectory(
                at: package.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try await SyntheticVideoFactory.makeVideo(
            at: package.appendingPathComponent("raw/screen.mp4"),
            frameCount: Int(leadingSeconds * 30),
            framesPerSecond: 30
        )
        try await SyntheticVideoFactory.makeVideo(
            at: package.appendingPathComponent("raw/segments/screen-001.mp4"),
            frameCount: Int(continuationSeconds * 30),
            framesPerSecond: 30
        )

        let manifest = TraceManifest(
            id: UUID(),
            kind: .recording,
            createdAt: Date(),
            title: "受损录屏",
            state: .ready,
            dimensions: TraceDimensions(width: 640, height: 360),
            assets: [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                TraceAsset(
                    role: .screenVideoSegment,
                    relativePath: "raw/segments/screen-001.mp4"
                )
            ]
        )
        var stored = manifest
        stored.durationSeconds = leadingSeconds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored).write(
            to: package.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let index = RecordingSegmentIndex(segments: [
            RecordingSegment(
                index: 0,
                timelineStartSeconds: 0,
                durationSeconds: leadingSeconds,
                screenRelativePath: "raw/screen.mp4"
            ),
            RecordingSegment(
                index: 1,
                timelineStartSeconds: leadingSeconds,
                durationSeconds: nil,
                screenRelativePath: "raw/segments/screen-001.mp4"
            )
        ])
        try encoder.encode(index).write(
            to: package.appendingPathComponent("events/segments.json"),
            options: .atomic
        )
        return package
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testUncountedContinuationSegmentIsReportedAsRecoverablePicture() async throws {
        let package = try await makeDamagedProject()
        let store = TraceProjectStore(rootDirectory: root)
        let assessed = await RecordingRecoveryInspector(store: store)
            .assess(packageURL: package)
        let assessment = try XCTUnwrap(assessed)

        XCTAssertTrue(assessment.isDamaged)
        XCTAssertTrue(assessment.canRebuildLongerRecording)
        XCTAssertEqual(assessment.presentedScreenSeconds, 1, accuracy: 0.15)
        XCTAssertEqual(assessment.availableScreenSeconds, 3, accuracy: 0.15)
        XCTAssertEqual(assessment.recoverableScreenSeconds, 2, accuracy: 0.15)
    }

    func testRebuildMergesTheMissingPictureAndKeepsEveryOriginalFile() async throws {
        let package = try await makeDamagedProject()
        let store = TraceProjectStore(rootDirectory: root)
        let inspector = RecordingRecoveryInspector(store: store)
        let assessed = await inspector.assess(packageURL: package)
        let assessment = try XCTUnwrap(assessed)

        let result = try await RecordingRecoveryRepair(store: store)
            .rebuild(packageURL: package, assessment: assessment)

        XCTAssertEqual(result.previousDurationSeconds, 1, accuracy: 0.15)
        XCTAssertEqual(result.durationSeconds, 3, accuracy: 0.15)
        XCTAssertEqual(result.addedSeconds, 2, accuracy: 0.15)

        let merged = try await duration(
            of: package.appendingPathComponent("raw/screen.mp4")
        )
        XCTAssertEqual(merged, 3, accuracy: 0.3)

        let manifest = try store.loadManifest(from: package)
        XCTAssertEqual(manifest.durationSeconds ?? 0, 3, accuracy: 0.15)
        // Handed back for the ordinary post-processing path to finish.
        XCTAssertEqual(manifest.state, .processing)

        // The repair is additive: segment zero's original video is archived
        // rather than replaced, so nothing that was on disk is gone.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(
            atPath: package.appendingPathComponent("raw/segments/screen-000.mp4").path
        ))
        XCTAssertTrue(fm.fileExists(
            atPath: package.appendingPathComponent("raw/segments/screen-001.mp4").path
        ))
        let archived = try await duration(
            of: package.appendingPathComponent("raw/segments/screen-000.mp4")
        )
        XCTAssertEqual(archived, 1, accuracy: 0.15)
    }

    func testRebuiltRecordingNoLongerReportsDamage() async throws {
        let package = try await makeDamagedProject()
        let store = TraceProjectStore(rootDirectory: root)
        let inspector = RecordingRecoveryInspector(store: store)
        let assessed = await inspector.assess(packageURL: package)
        let assessment = try XCTUnwrap(assessed)

        _ = try await RecordingRecoveryRepair(store: store)
            .rebuild(packageURL: package, assessment: assessment)

        let reassessed = await inspector.assess(packageURL: package)
        XCTAssertEqual(try XCTUnwrap(reassessed).findings, [])
    }

    func testRebuildingARecordingWithNothingToAddIsRefused() async throws {
        let store = TraceProjectStore(rootDirectory: root)
        let assessment = RecordingRecoveryAssessment(
            findings: [
                .sideTrackOutlivesScreen(
                    role: .microphone,
                    relativePath: "raw/microphone.caf",
                    screenSeconds: 10,
                    trackSeconds: 46
                )
            ],
            presentedScreenSeconds: 10,
            availableScreenSeconds: 10
        )

        // There is no more picture on disk. Fabricating one from a longer
        // audio track would invent content the user never recorded.
        do {
            _ = try await RecordingRecoveryRepair(store: store).rebuild(
                packageURL: root.appendingPathComponent("missing.screentrace"),
                assessment: assessment
            )
            XCTFail("rebuild should refuse a recording with no extra picture")
        } catch RecordingRecoveryRepairError.nothingToRebuild {
            // expected
        }
    }
}
