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
    }

    static func digest(
        for plan: AutoEditPlan,
        transcript: TranscriptDocument?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let renderedTranscript = plan.captions?.isEnabled == true
            ? transcript
            : nil
        let data = try encoder.encode(Input(
            plan: plan,
            transcript: renderedTranscript
        ))
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
