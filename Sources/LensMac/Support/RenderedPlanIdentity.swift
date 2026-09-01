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
        // Narration-trim suggestions do not affect rendering until accepted,
        // and accepting already rewrites `timeline`, which is digested. Keeping
        // the proposal list out of the identity stops a detection pass from
        // marking every existing preview as stale.
        var renderedPlan = plan
        renderedPlan.narrationTrims = nil
        let data = try encoder.encode(Input(
            plan: renderedPlan,
            transcript: renderedTranscript
        ))
        return "sha256:" + SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
