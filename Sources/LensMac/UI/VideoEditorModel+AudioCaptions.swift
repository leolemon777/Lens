import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
    func setAudioEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.isEnabled = enabled
        }
    }

    func setSystemVolume(_ value: Double) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.systemVolume = min(max(value, 0), 2)
        }
    }

    func setMicrophoneVolume(_ value: Double) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.microphoneVolume = min(max(value, 0), 2)
        }
    }

    func setMicrophoneNoiseReductionEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.reducesMicrophoneNoise = enabled
        }
    }

    func setNoiseReductionAmount(_ value: Double) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.noiseReductionAmount = min(max(value, 0), 1)
        }
    }

    func setLoudnessNormalizationEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.normalizesLoudness = enabled
        }
    }

    func setTargetLoudnessLUFS(_ value: Double) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.targetLoudnessLUFS = min(max(value, -24), -10)
        }
    }

    func setDuckingEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.ducksSystemUnderNarration = enabled
        }
    }

    func setCursorFollowStyle(_ style: AutoEditPlan.Cursor.FollowStyle) {
        mutate { plan in
            plan.cursor.followStyle = style
        }
    }

    func setCaptionsWordHighlight(_ enabled: Bool) {
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            plan.captions?.highlightsSpokenWords = enabled
        }
    }

    func setExportAspectRatio(_ aspectRatio: AutoEditPlan.Export.AspectRatio?) {
        mutate { plan in
            if plan.export == nil { plan.export = .init() }
            plan.export?.aspectRatio = aspectRatio
        }
    }

    // MARK: - 击键胶囊

    func setKeystrokesEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.showsKeystrokes = enabled
        }
    }

    /// Legacy projects predate keystroke data; regenerate it once from the
    /// recorded event file so the toggle works everywhere.
    func hydrateKeystrokesIfNeeded() {
        guard (plan.interaction?.keystrokes ?? []).isEmpty,
              let keyboardEventsURL,
              FileManager.default.fileExists(atPath: keyboardEventsURL.path) else {
            return
        }
        Task { [weak self] in
            let sourceDuration = self?.sourceDurationSeconds ?? 0
            let displays = await Task.detached(priority: .utility) { () -> [AutoEditPlan.KeystrokeDisplay] in
                let events = LensFailureLog.optional("editor.keystroke_events_read") {
                    try LensEventReader.read(
                    KeyboardEvent.self,
                    from: keyboardEventsURL
                    )
                } ?? []
                return KeystrokePlanner().displays(
                    events: events,
                    durationSeconds: sourceDuration
                )
            }.value
            guard let self, !displays.isEmpty else { return }
            var updated = self.plan
            if updated.interaction == nil { updated.interaction = .init() }
            updated.interaction?.keystrokes = displays
            self.plan = updated
            var baseline = self.savedPlan
            if baseline.interaction == nil { baseline.interaction = .init() }
            baseline.interaction?.keystrokes = displays
            self.savedPlan = baseline
            var persisted = self.persistedPlan
            if persisted.interaction == nil { persisted.interaction = .init() }
            persisted.interaction?.keystrokes = displays
            self.persistedPlan = persisted
            self.syncChangeState()
        }
    }

    // MARK: - 一键人声增强

    /// The applied preset when all three narration-polish switches are on;
    /// nil means enhancement is off (or the knobs were tuned by hand).
    var appliedVoiceEnhancementLevel: AutoEditPlan.Audio.VoiceEnhancementLevel? {
        guard let audio = plan.audio,
              audio.reducesMicrophoneNoise,
              audio.normalizesLoudness,
              audio.ducksSystemUnderNarration else { return nil }
        return AutoEditPlan.Audio.VoiceEnhancementLevel.allCases
            .min { lhs, rhs in
                abs(lhs.noiseReductionAmount - audio.noiseReductionAmount)
                    < abs(rhs.noiseReductionAmount - audio.noiseReductionAmount)
            }
    }

    func setVoiceEnhancement(
        _ level: AutoEditPlan.Audio.VoiceEnhancementLevel?
    ) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            guard let level else {
                plan.audio?.reducesMicrophoneNoise = false
                plan.audio?.normalizesLoudness = false
                plan.audio?.ducksSystemUnderNarration = false
                return
            }
            plan.audio?.reducesMicrophoneNoise = true
            plan.audio?.normalizesLoudness = true
            plan.audio?.ducksSystemUnderNarration = true
            plan.audio?.noiseReductionAmount = level.noiseReductionAmount
            plan.audio?.targetLoudnessLUFS = level.targetLoudnessLUFS
        }
    }

    var isAuditioningUnprocessedAudio: Bool { preAuditionAudio != nil }

    /// Temporarily bypasses narration processing so the user can hear the
    /// before/after difference against the same preview pipeline.
    func setUnprocessedAudition(_ enabled: Bool) {
        if enabled {
            guard preAuditionAudio == nil, let audio = plan.audio else { return }
            mutate { plan in
                plan.audio?.reducesMicrophoneNoise = false
                plan.audio?.normalizesLoudness = false
                plan.audio?.ducksSystemUnderNarration = false
            }
            preAuditionAudio = audio
        } else {
            guard let original = preAuditionAudio else { return }
            mutate { plan in
                plan.audio = original
            }
            preAuditionAudio = nil
        }
    }
    func setCaptionsEnabled(_ enabled: Bool) {
        guard hasTranscript else { return }
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            plan.captions?.isEnabled = enabled
        }
    }

    func setCaptionStyle(_ style: AutoEditPlan.Captions.Style) {
        guard hasTranscript else { return }
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            plan.captions?.style = style
        }
    }

    func setCaptionPosition(_ position: AutoEditPlan.Captions.Position) {
        guard hasTranscript else { return }
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            plan.captions?.position = position
        }
    }

    func setCaptionFontScale(_ value: Double) {
        guard hasTranscript else { return }
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            plan.captions?.fontScale = min(max(value, 0.7), 1.6)
        }
    }

    func setExportPreset(_ preset: AutoEditPlan.Export.Preset) {
        mutate { plan in
            if plan.export == nil { plan.export = .init(preset: .source) }
            plan.export?.preset = preset
        }
    }

    func setCaptionCueText(_ text: String, at index: Int) {
        mutateCaptionCues { cues in
            guard cues.indices.contains(index), cues[index].text != text else { return nil }
            var updated = cues
            updated[index].text = text
            return updated
        }
    }

    func selectCaptionCue(at index: Int?) {
        guard let index else {
            selectedCaptionCueIndex = nil
            return
        }
        guard captionSourceCues.indices.contains(index) else { return }
        selectedCaptionCueIndex = index
    }

    func captionOutputRanges(at index: Int) -> [VideoEditTimeRange] {
        let cues = captionSourceCues
        guard cues.indices.contains(index) else { return [] }
        let cue = cues[index]
        return timeline.outputRanges(forSourceRange: VideoEditTimeRange(
            startSeconds: cue.sourceStartSeconds,
            endSeconds: cue.sourceEndSeconds
        ))
    }

    func primaryCaptionOutputTime(at index: Int) -> Double? {
        captionOutputRanges(at: index).first?.startSeconds
    }

    func setCaptionCueStart(_ seconds: Double, at index: Int) {
        mutateCaptionCues { cues in
            CaptionCueEditor.retimed(
                cues,
                at: index,
                sourceStartSeconds: seconds,
                sourceDurationSeconds: sourceDurationSeconds
            )
        }
    }

    func setCaptionCueEnd(_ seconds: Double, at index: Int) {
        mutateCaptionCues { cues in
            CaptionCueEditor.retimed(
                cues,
                at: index,
                sourceEndSeconds: seconds,
                sourceDurationSeconds: sourceDurationSeconds
            )
        }
    }

    func canSplitCaptionCue(at index: Int, atOutputTime outputTime: Double) -> Bool {
        let cues = captionSourceCues
        guard cues.indices.contains(index),
              let sourceTime = timeline.position(atOutputTime: outputTime)?.sourceTimeSeconds else {
            return false
        }
        return CaptionCueEditor.split(
            cues,
            at: index,
            sourceTimeSeconds: sourceTime
        ) != nil
    }

    @discardableResult
    func splitCaptionCue(at index: Int, atOutputTime outputTime: Double) -> Bool {
        guard let sourceTime = timeline.position(atOutputTime: outputTime)?.sourceTimeSeconds else {
            return false
        }
        let changed = mutateCaptionCues { cues in
            CaptionCueEditor.split(
                cues,
                at: index,
                sourceTimeSeconds: sourceTime
            )
        }
        if changed { selectedCaptionCueIndex = index + 1 }
        return changed
    }

    @discardableResult
    func mergeCaptionCueWithNext(at index: Int) -> Bool {
        let changed = mutateCaptionCues { cues in
            CaptionCueEditor.mergedWithNext(
                cues,
                at: index,
                localeIdentifier: transcript?.localeIdentifier ?? "und"
            )
        }
        if changed { selectedCaptionCueIndex = index }
        return changed
    }

    func deleteCaptionCue(at index: Int) {
        let changed = mutateCaptionCues { cues in
            guard cues.indices.contains(index) else { return nil }
            var updated = cues
            updated.remove(at: index)
            return updated
        }
        guard changed else { return }
        selectedCaptionCueIndex = captionSourceCues.isEmpty
            ? nil
            : min(index, captionSourceCues.count - 1)
    }

    func restoreAutomaticCaptionText() {
        guard plan.captions?.customCues != nil else { return }
        mutate { $0.captions?.customCues = nil }
        selectedCaptionCueIndex = nil
    }
}
