import CryptoKit
import Foundation
import LensCore

/// Stable identity for every authored input that can change a rendered preview.
/// The value is persisted with media-level verification so an old green report
/// can never authorize exporting a preview generated from a different plan.
enum RenderedPlanIdentity {
    private struct Input: Encodable {
        let plan: AutoEditPlan
        let transcript: TranscriptDocument?
        let sourceFingerprint: String?
    }

    static func digest(
        for plan: AutoEditPlan,
        transcript: TranscriptDocument?,
        sourceURL: URL? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let renderedTranscript = plan.captions?.isEnabled == true
            ? transcript
            : nil
        // Narration-trim suggestions do not affect rendering until accepted,
        // and accepting already rewrites `timeline`, which is digested. Keeping
        // the proposal list out of the identity stops a detection pass from
        // marking every existing preview as stale.
        var renderedPlan = plan
        renderedPlan.narrationTrims = nil
        let data = try encoder.encode(Input(
            plan: renderedPlan,
            transcript: renderedTranscript,
            sourceFingerprint: try sourceURL.map(sourceFingerprint(for:))
        ))
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Computes the same identity without making an actor that owns a window
    /// read the complete source video synchronously. The synchronous variant
    /// remains available to render workers that are already off the UI actor.
    static func digestAsync(
        for plan: AutoEditPlan,
        transcript: TranscriptDocument?,
        sourceURL: URL? = nil
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try digest(for: plan, transcript: transcript, sourceURL: sourceURL)
        }.value
    }

    /// The rendered preview is only current for the exact raw asset it was
    /// generated from. Hashing in bounded chunks keeps identity checks from
    /// loading a multi-gigabyte recording into memory.
    private static func sourceFingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
