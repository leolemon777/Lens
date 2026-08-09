import Foundation
import XCTest
@testable import ScreenTraceCore

final class TraceProjectStoreTests: XCTestCase {
    func testScreenshotRoundTripCreatesOpenProjectPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TraceProjectStore(rootDirectory: root)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])

        let result = try store.saveScreenshot(
            pngData: pngData,
            width: 1440,
            height: 900,
            createdAt: createdAt,
            id: id
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.rawAssetURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.packageURL.appendingPathComponent("manifest.json").path
        ))
        XCTAssertEqual(try Data(contentsOf: result.rawAssetURL), pngData)

        let manifest = try store.loadManifest(from: result.packageURL)
        XCTAssertEqual(manifest.schemaVersion, TraceManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.kind, .screenshot)
        XCTAssertEqual(manifest.dimensions, TraceDimensions(width: 1440, height: 900))
        XCTAssertEqual(manifest.assets, [
            TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png")
        ])
    }

    func testInvalidDimensionsDoNotCreatePackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)

        XCTAssertThrowsError(try store.saveScreenshot(
            pngData: Data(),
            width: 0,
            height: 100
        )) { error in
            XCTAssertEqual(error as? TraceProjectStoreError, .invalidDimensions)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOCRRoundTripAddsAnalysisAssetWithoutChangingRawScreenshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let rawBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let screenshot = try store.saveScreenshot(
            pngData: rawBytes,
            width: 800,
            height: 500
        )
        let document = OCRDocument(
            engine: "test-engine",
            recognizedAt: Date(timeIntervalSince1970: 1_700_000_000),
            recognitionLanguages: ["zh-Hans", "en-US"],
            blocks: [
                OCRTextBlock(
                    text: "屏迹 ScreenTrace",
                    confidence: 0.98,
                    normalizedBounds: TraceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)
                )
            ]
        )

        let updated = try store.attachOCR(document, to: screenshot)
        let updatedAgain = try store.attachOCR(document, to: updated)

        XCTAssertEqual(try Data(contentsOf: screenshot.rawAssetURL), rawBytes)
        XCTAssertEqual(try store.loadOCR(from: screenshot.packageURL), document)
        XCTAssertEqual(updatedAgain.manifest.assets.filter { $0.role == .ocr }, [
            TraceAsset(role: .ocr, relativePath: "analysis/ocr.json")
        ])
        XCTAssertEqual(document.fullText, "屏迹 ScreenTrace")
    }

    func testOCRCannotBeAttachedToRecordingProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 640, height: 360)
        try Data([1]).write(to: session.videoURL)
        let recording = try store.finalizeRecording(session, durationSeconds: 1)
        let document = OCRDocument(
            engine: "test-engine",
            recognitionLanguages: [],
            blocks: []
        )

        XCTAssertThrowsError(try store.attachOCR(document, to: recording)) { error in
            XCTAssertEqual(error as? TraceProjectStoreError, .incompatibleTraceKind)
        }
    }

    func testScreenshotEditPlanAndRenderedPreviewPreserveOriginal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let rawBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let screenshot = try store.saveScreenshot(
            pngData: rawBytes,
            width: 1_000,
            height: 600
        )
        let plan = ScreenshotEditPlan(
            sourceDimensions: TraceDimensions(width: 1_000, height: 600),
            annotations: [
                ScreenshotAnnotation(
                    kind: .rectangle,
                    bounds: TraceRect(x: 0.1, y: 0.1, width: 0.4, height: 0.3)
                )
            ]
        )

        let withPlan = try store.writeScreenshotEditPlan(plan, to: screenshot)
        let renderedURL = screenshot.packageURL.appendingPathComponent("previews/annotated.png")
        try Data([1, 2, 3]).write(to: renderedURL)
        let completed = try store.completeScreenshotEditing(
            packageURL: screenshot.packageURL,
            renderedImageURL: renderedURL
        )

        XCTAssertEqual(try store.loadScreenshotEditPlan(from: screenshot.packageURL), plan)
        XCTAssertEqual(try Data(contentsOf: screenshot.rawAssetURL), rawBytes)
        XCTAssertTrue(withPlan.manifest.assets.contains {
            $0.role == .screenshotEditPlan && $0.relativePath == "edits/screenshot-edit.json"
        })
        XCTAssertTrue(completed.manifest.assets.contains {
            $0.role == .renderedScreenshot && $0.relativePath == "previews/annotated.png"
        })
    }

    func testScreenshotEditPlanRejectsMismatchedSourceDimensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let screenshot = try store.saveScreenshot(
            pngData: Data([1]),
            width: 800,
            height: 500
        )
        let plan = ScreenshotEditPlan(
            sourceDimensions: TraceDimensions(width: 801, height: 500)
        )

        XCTAssertThrowsError(try store.writeScreenshotEditPlan(plan, to: screenshot)) { error in
            XCTAssertEqual(error as? TraceProjectStoreError, .invalidDimensions)
        }
    }

    func testRecordingLifecycleCreatesEventTracksAndFinalizesManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)

        let session = try store.beginRecording(width: 2560, height: 1440)
        XCTAssertEqual(session.manifest.state, .capturing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.pointerEventsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.clickEventsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.editPlanURL.path))
        try Data([0, 1, 2, 3]).write(to: session.videoURL)

        let saved = try store.finalizeRecording(session, durationSeconds: 12.5)
        XCTAssertEqual(saved.manifest.state, .processing)
        XCTAssertEqual(saved.manifest.durationSeconds, 12.5)
        let reloaded = try store.loadManifest(from: session.packageURL)
        XCTAssertEqual(reloaded, saved.manifest)
    }

    func testRecordingManifestPersistsWindowCaptureContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let source = CaptureGeometry.windowRecordingSource(
            WindowSelectionCandidate(
                id: 42,
                globalFrame: CGRect(x: 120, y: 80, width: 900, height: 600),
                frontToBackOrder: 0,
                title: "设计稿",
                applicationName: "Sketch"
            )
        )

        let session = try store.beginRecording(
            width: 1_800,
            height: 1_200,
            captureSource: TraceCaptureMetadata(recordingSource: source)
        )
        let manifest = try store.loadManifest(from: session.packageURL)

        XCTAssertEqual(manifest.schemaVersion, TraceManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.captureSource?.mode, .window)
        XCTAssertEqual(manifest.captureSource?.windowID, 42)
        XCTAssertEqual(manifest.captureSource?.windowTitle, "设计稿")
        XCTAssertEqual(manifest.captureSource?.applicationName, "Sketch")
        XCTAssertTrue(manifest.title.hasPrefix("Sketch 窗口录屏"))
    }

    func testRecordingCanReserveAndRemovePhysicalMicrophoneAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)

        let session = try store.beginRecording(
            width: 1_280,
            height: 720,
            includesMicrophone: true
        )
        let microphoneURL = try XCTUnwrap(session.microphoneURL)
        XCTAssertEqual(microphoneURL.lastPathComponent, "microphone.caf")
        XCTAssertTrue(session.manifest.assets.contains {
            $0.role == .microphone && $0.relativePath == "raw/microphone.caf"
        })

        try Data([1, 2, 3]).write(to: microphoneURL)
        try store.removeAsset(role: .microphone, from: session.packageURL)
        try Data([9, 8, 7]).write(to: session.videoURL)
        let finalized = try store.finalizeRecording(session, durationSeconds: 2)
        XCTAssertFalse(finalized.manifest.assets.contains {
            $0.role == .microphone
        })
        XCTAssertEqual(try Data(contentsOf: microphoneURL), Data([1, 2, 3]))
    }

    func testLegacyPointOneManifestDecodesWithoutCaptureMetadata() throws {
        let json = """
        {
          "schemaVersion": "0.1",
          "id": "12345678-1234-1234-1234-123456789ABC",
          "kind": "recording",
          "createdAt": "2026-08-09T12:00:00Z",
          "title": "旧录屏",
          "state": "ready",
          "dimensions": { "width": 1280, "height": 720 },
          "assets": [
            { "role": "screenVideo", "relativePath": "raw/screen.mp4" }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(TraceManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.schemaVersion, "0.1")
        XCTAssertNil(manifest.captureSource)
        XCTAssertEqual(manifest.dimensions, TraceDimensions(width: 1_280, height: 720))
    }

    func testRecordingCannotFinalizeWithoutNonemptyRawVideo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1920, height: 1080)

        XCTAssertThrowsError(try store.finalizeRecording(session, durationSeconds: 1)) { error in
            XCTAssertEqual(error as? TraceProjectStoreError, .missingRawRecording)
        }
        FileManager.default.createFile(atPath: session.videoURL.path, contents: nil)
        XCTAssertThrowsError(try store.finalizeRecording(session, durationSeconds: 1)) { error in
            XCTAssertEqual(error as? TraceProjectStoreError, .emptyRawRecording)
        }
    }

    func testCompletedAutoPreviewMovesProjectToReadyAndAddsAsset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1280, height: 720)
        try Data([1]).write(to: session.videoURL)
        _ = try store.finalizeRecording(session, durationSeconds: 2)
        let renderedURL = session.packageURL.appendingPathComponent("previews/auto.mp4")
        try Data([2, 3]).write(to: renderedURL)

        let completed = try store.completeProcessing(
            packageURL: session.packageURL,
            renderedVideoURL: renderedURL
        )

        XCTAssertEqual(completed.manifest.state, .ready)
        XCTAssertTrue(completed.manifest.assets.contains {
            $0.role == .renderedVideo && $0.relativePath == "previews/auto.mp4"
        })
        XCTAssertEqual(try store.loadAutoEditPlan(from: session.packageURL), AutoEditPlan())
    }

    func testInterruptedRecordingRemainsDiscoverable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1920, height: 1080)

        try store.markRecordingInterrupted(session)

        XCTAssertEqual(try store.loadManifest(from: session.packageURL).state, .interrupted)
    }

    func testAutoEditPlanUsesRecordedClickTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1920, height: 1080)
        let writer = try JSONLinesWriter<ClickEvent>(url: session.clickEventsURL)
        try await writer.append(ClickEvent(
            time: 1,
            button: .left,
            phase: .down,
            location: TracePoint(x: 900, y: 500),
            normalizedLocation: TracePoint(x: 0.47, y: 0.46),
            displayID: 1,
            clickCount: 1
        ))
        try await writer.close()

        let plan = try store.writeAutoEditPlan(for: session, durationSeconds: 4)

        XCTAssertTrue(plan.camera.keyframes.contains { $0.reason == .clickFocus })
        XCTAssertEqual(plan.interaction?.clickPulses.count, 1)
        let persisted = try JSONDecoder().decode(
            AutoEditPlan.self,
            from: Data(contentsOf: session.editPlanURL)
        )
        XCTAssertEqual(persisted, plan)
    }

    func testLaunchRecoveryMarksCapturingProjectsInterruptedWithoutDeletingMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1920, height: 1080)
        let partialBytes = Data([1, 2, 3, 4])
        try partialBytes.write(to: session.videoURL)

        let recovered = store.recoverInterruptedRecordings()

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].manifest.id, session.manifest.id)
        XCTAssertEqual(recovered[0].manifest.state, .interrupted)
        XCTAssertEqual(try Data(contentsOf: session.videoURL), partialBytes)
        XCTAssertTrue(store.recoverInterruptedRecordings().isEmpty)
    }
}
