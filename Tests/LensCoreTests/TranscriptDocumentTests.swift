import Foundation
import XCTest
@testable import LensCore

final class TranscriptDocumentTests: XCTestCase {
    func testDocumentNormalizesSegmentsAndRoundTripsOpenSchema() throws {
        let document = TranscriptDocument(
            engine: " apple-speech ",
            generatedAt: Date(timeIntervalSince1970: 100.8),
            localeIdentifier: " zh-CN ",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                TranscriptSegment(
                    startSeconds: 1.2,
                    endSeconds: 1.6,
                    text: " 世界 ",
                    confidence: 1.4
                ),
                TranscriptSegment(
                    startSeconds: -1,
                    endSeconds: 0.4,
                    text: "你好",
                    confidence: -0.2
                ),
                TranscriptSegment(
                    startSeconds: .nan,
                    endSeconds: .nan,
                    text: "  ",
                    confidence: .nan
                )
            ]
        )

        XCTAssertEqual(document.engine, "apple-speech")
        XCTAssertEqual(document.localeIdentifier, "zh-CN")
        XCTAssertEqual(document.generatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(document.fullText, "你好 世界")
        XCTAssertEqual(document.segments.map(\.text), ["你好", "世界"])
        XCTAssertEqual(document.segments.map(\.confidence), [0, 1])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            TranscriptDocument.self,
            from: encoder.encode(document)
        )
        XCTAssertEqual(decoded, document)
    }

    func testRecordingTranscriptPersistsAndBecomesSearchable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensTranscriptTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1_280, height: 720)
        try Data([1, 2, 3]).write(to: session.videoURL)
        let saved = try store.finalizeRecording(
            session,
            durationSeconds: 4,
            state: .ready
        )
        let transcript = TranscriptDocument(
            engine: "test-local",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            fullText: "发布计划和设计评审",
            segments: [
                TranscriptSegment(
                    startSeconds: 0.2,
                    endSeconds: 2.3,
                    text: "发布计划和设计评审",
                    confidence: 0.93
                )
            ]
        )

        let updated = try store.attachTranscript(transcript, to: saved)

        XCTAssertEqual(updated.manifest.schemaVersion, LensManifest.currentSchemaVersion)
        XCTAssertTrue(updated.manifest.assets.contains { $0.role == .transcript })
        XCTAssertEqual(try store.loadTranscript(from: saved.packageURL), transcript)
        let entries = store.libraryEntries()
        XCTAssertEqual(entries.first?.transcriptText, transcript.fullText)
        XCTAssertEqual(
            LensLibrarySearch.filter(
                entries,
                query: "发布 设计",
                filter: .recordings
            ).map(\.manifest.id),
            [saved.manifest.id]
        )
    }
}
