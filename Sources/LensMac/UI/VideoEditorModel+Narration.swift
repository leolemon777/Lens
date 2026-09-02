import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
    enum NarrationTrimDetectionState {
        case detecting
        case ready
    }

    func outputTimes(forNarrationTrim suggestion: NarrationTrimSuggestion) -> [Double] {
        timeline.outputTimes(forSourceTime: suggestion.startSeconds)
    }

    func acceptNarrationTrim(_ id: UUID) {
        guard let suggestion = narrationTrimSuggestions.first(where: { $0.id == id }),
              suggestion.status == .pending else { return }
        mutate(timelineChanged: true) { plan in
            guard var timeline = plan.timeline,
                  timeline.removeSourceRange(
                    startSeconds: suggestion.startSeconds,
                    endSeconds: suggestion.endSeconds
                  ) else { return }
            plan.timeline = timeline
            plan.narrationTrims = Self.updating(
                plan.narrationTrims ?? [],
                id: id,
                status: .accepted
            )
        }
    }

    func acceptAllPendingNarrationTrims() {
        let pending = pendingNarrationTrims
        guard !pending.isEmpty else { return }
        mutate(timelineChanged: true) { plan in
            guard var timeline = plan.timeline else { return }
            var acceptedIDs = Set<UUID>()
            for suggestion in pending
            where timeline.removeSourceRange(
                startSeconds: suggestion.startSeconds,
                endSeconds: suggestion.endSeconds
            ) {
                acceptedIDs.insert(suggestion.id)
            }
            guard !acceptedIDs.isEmpty else { return }
            plan.timeline = timeline
            plan.narrationTrims = (plan.narrationTrims ?? []).map { item in
                guard acceptedIDs.contains(item.id) else { return item }
                var updated = item
                updated.status = .accepted
                return updated
            }
        }
    }

    func rejectNarrationTrim(_ id: UUID) {
        setNarrationTrimStatus(id, .rejected)
    }

    /// Brings a previously rejected suggestion back into the review list.
    func restoreNarrationTrim(_ id: UUID) {
        setNarrationTrimStatus(id, .pending)
    }

    func setNarrationTrimStatus(
        _ id: UUID,
        _ status: NarrationTrimSuggestion.Status
    ) {
        mutate { plan in
            let current = plan.narrationTrims ?? []
            guard current.contains(where: { $0.id == id && $0.status != status }) else {
                return
            }
            plan.narrationTrims = Self.updating(current, id: id, status: status)
        }
    }

    private static func updating(
        _ suggestions: [NarrationTrimSuggestion],
        id: UUID,
        status: NarrationTrimSuggestion.Status
    ) -> [NarrationTrimSuggestion] {
        suggestions.map { item in
            guard item.id == id else { return item }
            var updated = item
            updated.status = status
            return updated
        }
    }

    /// Detects silence, filler words, and buffer dead air once per project.
    /// Results land in the plan without marking it dirty: pending suggestions
    /// never change rendering, so there is nothing to re-render or save until
    /// the user accepts one.
    func startNarrationTrimDetectionIfNeeded() {
        guard plan.narrationTrims == nil else { return }
        guard let microphoneURL else { return }
        narrationTrimDetectionState = .detecting
        narrationTrimDetectionRevision &+= 1
        let revision = narrationTrimDetectionRevision
        let thresholdDecibels = plan.audio?.narrationThresholdDecibels ?? -42
        Task { [weak self] in
            let spans = await Task.detached(priority: .utility) { () -> [NarrationTrimPlanner.Span]? in
                let ranges = LensFailureLog.optional("editor.narration_trim_analyze") {
                    try NarrationActivityAnalyzer().analyze(
                    url: microphoneURL,
                    thresholdDecibels: thresholdDecibels
                    )
                }
                return ranges?.map {
                    NarrationTrimPlanner.Span(
                        startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds
                    )
                }
            }.value
            guard let self, self.narrationTrimDetectionRevision == revision else { return }
            var updated = self.plan
            // A failed analysis still records an empty list: the recording is
            // treated as "reviewed, nothing to suggest" rather than retried
            // on every editor open.
            updated.narrationTrims = NarrationTrimPlanner().suggestions(
                narrationRanges: spans ?? [],
                transcript: self.transcript,
                durationSeconds: self.sourceDurationSeconds
            )
            self.plan = updated
            var baseline = self.savedPlan
            baseline.narrationTrims = updated.narrationTrims
            self.savedPlan = baseline
            var persisted = self.persistedPlan
            persisted.narrationTrims = updated.narrationTrims
            self.persistedPlan = persisted
            self.syncChangeState()
            self.narrationTrimDetectionState = .ready
        }
    }
}
