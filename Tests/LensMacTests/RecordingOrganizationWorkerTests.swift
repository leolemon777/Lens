import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingOrganizationWorkerTests: XCTestCase {
    private struct InjectedFailure: Error, Sendable {
        let name: String
    }

    private func makeLens() -> SavedLens {
        let packageURL = URL(fileURLWithPath: "/tmp/organization-worker.lens")
        let manifest = LensManifest(
            kind: .recording,
            title: "worker",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        return SavedLens(
            packageURL: packageURL,
            rawAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            manifest: manifest
        )
    }

    func testWorkerForwardsSuppliedDocumentsAndToken() async throws {
        let lens = makeLens()
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["en-US"],
            blocks: []
        )
        let transcript = TranscriptDocument(
            engine: "test",
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: []
        )
        let token = RecordingTaskToken(
            id: UUID(),
            packageURL: lens.packageURL,
            kind: .organization,
            version: "v1"
        )
        var received: RecordingOrganizationWorkRequest?
        let worker = RecordingOrganizationWorker { request in
            received = request
            return LensInsightsDocument(
                engine: "test",
                suggestedTitle: "title",
                summary: "summary",
                tags: ["test"]
            )
        }

        _ = try await worker.run(
            RecordingOrganizationWorkRequest(
                lens: lens,
                suppliedOCR: ocr,
                suppliedTranscript: transcript,
                taskToken: token
            )
        )

        XCTAssertEqual(received?.lens, lens)
        XCTAssertEqual(received?.suppliedOCR, ocr)
        XCTAssertEqual(received?.suppliedTranscript, transcript)
        XCTAssertEqual(received?.taskToken, token)
    }

    func testWorkerPropagatesCancellation() async {
        let worker = RecordingOrganizationWorker { _ in
            throw CancellationError()
        }
        let lens = makeLens()
        let request = RecordingOrganizationWorkRequest(
            lens: lens,
            taskToken: RecordingTaskToken(
                id: UUID(),
                packageURL: lens.packageURL,
                kind: .organization,
                version: "v1"
            )
        )

        do {
            _ = try await worker.run(request)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStoreBackedWorkerKeepsOptionalReadFailuresInjectable() async throws {
        let lens = makeLens()
        let worker = RecordingOrganizationWorker(
            loadManifest: { _ in lens.manifest },
            loadOCR: { _ in throw InjectedFailure(name: "ocr") },
            loadTranscript: { _ in throw InjectedFailure(name: "transcript") },
            loadInsights: { _ in throw InjectedFailure(name: "insights") }
        )

        let result = try await worker.run(
            RecordingOrganizationWorkRequest(
                lens: lens,
                taskToken: RecordingTaskToken(
                    id: UUID(),
                    packageURL: lens.packageURL,
                    kind: .organization,
                    version: "injected-read-failures"
                )
            )
        )

        XCTAssertEqual(result.suggestedTitle, "worker")
        XCTAssertTrue(result.summary.isEmpty)
        XCTAssertTrue(result.tags.contains("录屏"))
    }

    func testStoreBackedWorkerPropagatesManifestFailure() async {
        let lens = makeLens()
        let worker = RecordingOrganizationWorker(
            loadManifest: { _ in
                throw InjectedFailure(name: "manifest")
            },
            loadOCR: { _ in throw InjectedFailure(name: "ocr") },
            loadTranscript: { _ in throw InjectedFailure(name: "transcript") },
            loadInsights: { _ in throw InjectedFailure(name: "insights") }
        )

        do {
            _ = try await worker.run(
                RecordingOrganizationWorkRequest(
                    lens: lens,
                    taskToken: RecordingTaskToken(
                        id: UUID(),
                        packageURL: lens.packageURL,
                        kind: .organization,
                        version: "manifest-failure"
                    )
                )
            )
            XCTFail("Expected the injected manifest failure to propagate")
        } catch let error as InjectedFailure {
            XCTAssertEqual(error.name, "manifest")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
