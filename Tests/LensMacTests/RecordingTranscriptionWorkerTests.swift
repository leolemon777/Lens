import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingTranscriptionWorkerTests: XCTestCase {
    private struct InjectedFailure: Error, Sendable {}

    private func makeEntry() -> LensLibraryEntry {
        let id = UUID()
        let packageURL = URL(fileURLWithPath: "/tmp/transcription-worker-\(id).lens")
        let manifest = LensManifest(
            id: id,
            kind: .recording,
            title: "worker",
            dimensions: LensDimensions(width: 1, height: 1),
            assets: [LensAsset(role: .screenVideo, relativePath: "raw/screen.mp4")]
        )
        return LensLibraryEntry(
            packageURL: packageURL,
            manifest: manifest,
            primaryAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            displayAssetURL: packageURL.appendingPathComponent("raw/screen.mp4"),
            ocrText: nil,
            transcriptText: nil,
            insights: nil
        )
    }

    func testWorkerForwardsEntryModeAndToken() async throws {
        let entry = makeEntry()
        let token = RecordingTaskToken(
            id: UUID(),
            packageURL: entry.packageURL,
            kind: .transcription,
            version: "v1"
        )
        var received: RecordingTranscriptionWorkRequest?
        let worker = RecordingTranscriptionWorker { request in
            received = request
            return TranscriptDocument(
                engine: "test",
                localeIdentifier: "en-US",
                isOnDevice: true,
                sourceRole: .screenVideo,
                segments: []
            )
        }

        _ = try await worker.run(
            RecordingTranscriptionWorkRequest(
                entry: entry,
                automatic: true,
                taskToken: token
            )
        )

        XCTAssertEqual(received?.entry, entry)
        XCTAssertEqual(received?.automatic, true)
        XCTAssertEqual(received?.taskToken, token)
    }

    func testWorkerPropagatesCancellation() async {
        let worker = RecordingTranscriptionWorker { _ in
            throw CancellationError()
        }
        let entry = makeEntry()
        let request = RecordingTranscriptionWorkRequest(
            entry: entry,
            automatic: false,
            taskToken: RecordingTaskToken(
                id: UUID(),
                packageURL: entry.packageURL,
                kind: .transcription,
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

    func testInjectedPolicyForwardsSourceLocaleAndProgress() async throws {
        let entry = makeEntry()
        var toastTitle = ""
        var progress: (id: UUID, completed: Int, total: Int)?
        let worker = RecordingTranscriptionWorker(
            authorizationStatus: { .authorized },
            requestAuthorization: { .authorized },
            source: { _ in
                RecordingTranscriptionSource(
                    url: entry.primaryAssetURL,
                    role: .microphone
                )
            },
            presentPermission: {},
            presentToast: { title, _, _ in
                toastTitle = title
            },
            reportProgress: { id, completed, total in
                progress = (id, completed, total)
            },
            localeIdentifier: { "zh-Hans" },
            transcribe: { audioURL, localeIdentifier, sourceRole, report in
                XCTAssertEqual(audioURL, entry.primaryAssetURL)
                XCTAssertEqual(localeIdentifier, "zh-Hans")
                XCTAssertEqual(sourceRole, .microphone)
                report(2, 3)
                return TranscriptDocument(
                    engine: "test",
                    localeIdentifier: localeIdentifier,
                    isOnDevice: true,
                    sourceRole: sourceRole,
                    segments: []
                )
            }
        )

        let request = RecordingTranscriptionWorkRequest(
            entry: entry,
            automatic: false,
            taskToken: RecordingTaskToken(
                id: UUID(),
                packageURL: entry.packageURL,
                kind: .transcription,
                version: "injected-policy"
            )
        )
        let document = try await worker.run(request)

        XCTAssertEqual(document.localeIdentifier, "zh-Hans")
        XCTAssertEqual(toastTitle, "正在本机生成转写")
        XCTAssertEqual(progress?.id, entry.id)
        XCTAssertEqual(progress?.completed, 2)
        XCTAssertEqual(progress?.total, 3)
    }

    func testInjectedAuthorizationFailureStopsBeforeSourceOrTranscription() async {
        let entry = makeEntry()
        var sourceCalled = false
        var transcribeCalled = false
        let worker = RecordingTranscriptionWorker(
            authorizationStatus: { .denied },
            requestAuthorization: { .authorized },
            source: { _ in
                sourceCalled = true
                return RecordingTranscriptionSource(
                    url: entry.primaryAssetURL,
                    role: .screenVideo
                )
            },
            presentPermission: {},
            presentToast: { _, _, _ in },
            reportProgress: { _, _, _ in },
            localeIdentifier: { "en-US" },
            transcribe: { _, _, _, _ in
                transcribeCalled = true
                throw InjectedFailure()
            }
        )

        do {
            _ = try await worker.run(
                RecordingTranscriptionWorkRequest(
                    entry: entry,
                    automatic: false,
                    taskToken: RecordingTaskToken(
                        id: UUID(),
                        packageURL: entry.packageURL,
                        kind: .transcription,
                        version: "authorization-denied"
                    )
                )
            )
            XCTFail("Expected authorization failure")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .authorizationDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(sourceCalled)
        XCTAssertFalse(transcribeCalled)
    }
}
