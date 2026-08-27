import Foundation
import XCTest
@testable import LensCore

final class ProjectSchemaCompatibilityTests: XCTestCase {
    func testRegistryMatchesEveryCurrentPortableDocumentVersion() {
        XCTAssertEqual(LensProjectSchema.manifest.currentVersion, LensManifest.currentSchemaVersion)
        XCTAssertEqual(LensProjectSchema.autoEditPlan.currentVersion, AutoEditPlan.currentSchemaVersion)
        XCTAssertEqual(
            LensProjectSchema.screenshotEditPlan.currentVersion,
            ScreenshotEditPlan.currentSchemaVersion
        )
        XCTAssertEqual(
            LensProjectSchema.recordingSegments.currentVersion,
            RecordingSegmentIndex.currentSchemaVersion
        )
        XCTAssertEqual(
            LensProjectSchema.scrollingCapture.currentVersion,
            ScrollingCapturePlan.currentSchemaVersion
        )
        XCTAssertEqual(LensProjectSchema.ocr.currentVersion, OCRDocument.currentSchemaVersion)
        XCTAssertEqual(
            LensProjectSchema.transcript.currentVersion,
            TranscriptDocument.currentSchemaVersion
        )
        XCTAssertEqual(
            LensProjectSchema.insights.currentVersion,
            LensInsightsDocument.currentSchemaVersion
        )
        XCTAssertEqual(Set(LensProjectSchema.portableDocuments.map(\.relativePath)).count, 8)
    }

    func testLegacyRecordingGoldenProjectLoadsWithoutRewritingAnyFile() throws {
        let projectURL = try workingCopyOfFixture(named: "LegacyRecordingV0_1")
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let before = try fileSnapshot(at: projectURL)
        let store = LensProjectStore(rootDirectory: projectURL.deletingLastPathComponent())

        let manifest = try store.loadManifest(from: projectURL)
        let editPlan = try store.loadAutoEditPlan(from: projectURL)
        let segments = try store.loadRecordingSegmentIndex(from: projectURL)
        let transcript = try store.loadTranscript(from: projectURL)
        let insights = try store.loadInsights(from: projectURL)

        XCTAssertEqual(manifest.schemaVersion, "0.1")
        XCTAssertEqual(manifest.kind, .recording)
        XCTAssertEqual(editPlan.schemaVersion, "0.1")
        XCTAssertNil(editPlan.presenterCamera)
        XCTAssertNil(editPlan.export)
        XCTAssertEqual(segments.schemaVersion, "0.1")
        XCTAssertEqual(segments.completedDurationSeconds, 8)
        XCTAssertEqual(transcript.schemaVersion, "0.1")
        XCTAssertEqual(transcript.fullText, "旧版项目仍然可以读取")
        XCTAssertEqual(insights.schemaVersion, "0.1")
        XCTAssertNil(insights.customization)
        XCTAssertEqual(try fileSnapshot(at: projectURL), before)
    }

    func testLegacyScreenshotGoldenProjectLoadsWithoutRewritingAnyFile() throws {
        let projectURL = try workingCopyOfFixture(named: "LegacyScreenshotV0_1")
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let before = try fileSnapshot(at: projectURL)
        let store = LensProjectStore(rootDirectory: projectURL.deletingLastPathComponent())

        let manifest = try store.loadManifest(from: projectURL)
        let editPlan = try store.loadScreenshotEditPlan(from: projectURL)
        let ocr = try store.loadOCR(from: projectURL)
        let scrollingCapture = try store.loadScrollingCapturePlan(from: projectURL)

        XCTAssertEqual(manifest.schemaVersion, "0.1")
        XCTAssertEqual(manifest.kind, .screenshot)
        XCTAssertEqual(editPlan.schemaVersion, "0.2")
        XCTAssertNil(editPlan.canvasStyle)
        XCTAssertEqual(ocr.schemaVersion, "0.1")
        XCTAssertEqual(ocr.fullText, "Legacy OCR")
        XCTAssertEqual(scrollingCapture.schemaVersion, "0.1")
        XCTAssertEqual(scrollingCapture.outputDimensions.height, 900)
        XCTAssertEqual(try fileSnapshot(at: projectURL), before)
    }

    func testFutureAndMalformedSchemasAreRejectedInsteadOfSilentlyOpened() throws {
        let projectURL = try workingCopyOfFixture(named: "LegacyRecordingV0_1")
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        let future = original.replacingOccurrences(
            of: #""schemaVersion": "0.1""#,
            with: #""schemaVersion": "0.10""#
        )
        try Data(future.utf8).write(to: manifestURL, options: .atomic)
        let store = LensProjectStore(rootDirectory: projectURL.deletingLastPathComponent())

        XCTAssertThrowsError(try store.loadManifest(from: projectURL)) { error in
            XCTAssertEqual(
                error as? LensSchemaCompatibilityError,
                .unsupported(
                    document: "manifest.json",
                    found: "0.10",
                    supported: "0.1...0.9"
                )
            )
        }
        XCTAssertTrue(store.libraryEntries().isEmpty)
        XCTAssertThrowsError(try LensProjectSchema.manifest.validate("future")) { error in
            XCTAssertEqual(
                error as? LensSchemaCompatibilityError,
                .malformed(document: "manifest.json", found: "future")
            )
        }
    }

    func testWriterRejectsUnsupportedSchemaBeforeMutatingProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensSchemaWriteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let saved = try store.saveScreenshot(
            pngData: Data([1, 2, 3]),
            width: 640,
            height: 360
        )
        let manifestURL = saved.packageURL.appendingPathComponent("manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let unsupported = ScreenshotEditPlan(
            schemaVersion: "9.9",
            sourceDimensions: LensDimensions(width: 640, height: 360)
        )

        XCTAssertThrowsError(try store.writeScreenshotEditPlan(unsupported, to: saved)) { error in
            XCTAssertEqual(
                error as? LensSchemaCompatibilityError,
                .unsupported(
                    document: "screenshot-edit.json",
                    found: "9.9",
                    supported: "0.2...0.3"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: saved.packageURL.appendingPathComponent("edits/screenshot-edit.json").path
        ))
    }

    private func workingCopyOfFixture(named name: String) throws -> URL {
        guard let resources = Bundle.module.resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let source = resources
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensSchemaTests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("\(name).lens", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func fileSnapshot(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var snapshot: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            snapshot[relativePath] = try Data(contentsOf: url)
        }
        return snapshot
    }
}
