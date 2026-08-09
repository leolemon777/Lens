import AppKit
import Foundation
import ScreenTraceCore

@MainActor
final class VideoEditorModel: ObservableObject {
    @Published private(set) var plan: AutoEditPlan
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var isDirty = false
    @Published private(set) var isProcessing = false
    @Published private(set) var presenterThumbnail: NSImage?

    let sourceDurationSeconds: Double
    let hasCameraTrack: Bool
    let hasMicrophoneTrack: Bool
    let transcript: TranscriptDocument?
    var onTimelineChanged: ((VideoEditTimeline) -> Void)?

    private let initialPlan: AutoEditPlan
    private var savedPlan: AutoEditPlan
    private let automaticCaptionSourceCues: [CaptionSourceCue]
    private var undoHistory: [AutoEditPlan] = []
    private var redoHistory: [AutoEditPlan] = []
    private var presenterInteractionStartPlan: AutoEditPlan?
    private var captionPlacementCache: (
        configuration: AutoEditPlan.Captions,
        timeline: VideoEditTimeline,
        cues: [CaptionCue]
    )?

    init(
        plan requestedPlan: AutoEditPlan,
        sourceDurationSeconds: Double,
        hasCameraTrack: Bool,
        hasMicrophoneTrack: Bool = false,
        transcript: TranscriptDocument? = nil
    ) {
        let duration = max(sourceDurationSeconds.isFinite ? sourceDurationSeconds : 0, 0)
        var plan = requestedPlan
        plan.schemaVersion = AutoEditPlan.currentSchemaVersion
        plan.timeline = (plan.timeline ?? VideoEditTimeline(
            sourceDurationSeconds: duration
        )).normalized(sourceDurationSeconds: duration)
        plan.captions?.customCues?.sort {
            if $0.sourceStartSeconds != $1.sourceStartSeconds {
                return $0.sourceStartSeconds < $1.sourceStartSeconds
            }
            return $0.sourceEndSeconds < $1.sourceEndSeconds
        }
        let automaticCaptionSourceCues = transcript.map {
            CaptionCuePlanner.sourceCues(
                transcript: $0,
                configuration: AutoEditPlan.Captions(
                    maxCharactersPerCue: plan.captions?.maxCharactersPerCue ?? 28
                )
            )
        } ?? []
        self.plan = plan
        initialPlan = plan
        savedPlan = plan
        self.automaticCaptionSourceCues = automaticCaptionSourceCues
        self.sourceDurationSeconds = duration
        self.hasCameraTrack = hasCameraTrack
        self.hasMicrophoneTrack = hasMicrophoneTrack
        self.transcript = transcript
        selectedSegmentID = plan.timeline?.activeSegments.first?.id
    }

    var timeline: VideoEditTimeline {
        plan.timeline ?? VideoEditTimeline(sourceDurationSeconds: sourceDurationSeconds)
    }

    var activeSegments: [VideoEditSegment] { timeline.activeSegments }
    var segmentLayouts: [VideoEditSegmentLayout] { timeline.segmentLayouts }
    var resolvedTransitions: [VideoEditResolvedTransition] { timeline.resolvedTransitions }
    var outputDurationSeconds: Double { timeline.outputDurationSeconds }
    var selectedSegment: VideoEditSegment? {
        guard let selectedSegmentID else { return nil }
        return timeline.segments.first { $0.id == selectedSegmentID }
    }
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var canRemoveSelectedSegment: Bool {
        selectedSegment?.isEnabled == true && activeSegments.count > 1
    }
    var canTransitionFromSelectedSegment: Bool {
        guard let selectedSegmentID,
              let index = activeSegments.firstIndex(where: { $0.id == selectedSegmentID }) else {
            return false
        }
        return index < activeSegments.count - 1
    }
    var selectedTransitionKind: VideoEditTransition.Kind {
        selectedSegment?.transitionToNext?.kind ?? .cut
    }
    var selectedTransitionDuration: Double {
        selectedSegment?.transitionToNext?.durationSeconds ?? 0.35
    }
    var selectedResolvedTransitionDuration: Double? {
        guard let selectedSegmentID else { return nil }
        return resolvedTransitions.first {
            $0.fromSegmentID == selectedSegmentID
        }?.durationSeconds
    }
    var cameraMotionEnabled: Bool { plan.camera.mode != "off" }
    var cursorEnabled: Bool { plan.cursor.isEnabled != false }
    var clickPulseEnabled: Bool { plan.interaction?.showsClickPulse != false }
    var canvasEnabled: Bool { plan.canvas?.isEnabled != false }
    var presenterEnabled: Bool { plan.presenterCamera?.isEnabled == true }
    var presenterAvoidanceEnabled: Bool {
        plan.presenterCamera?.automaticallyAvoidsContent != false
    }
    var presenterKeyframeCount: Int { plan.presenterCamera?.keyframes.count ?? 0 }
    var presenterKeyframeOutputTimes: [Double] {
        (plan.presenterCamera?.keyframes ?? [])
            .flatMap { timeline.outputTimes(forSourceTime: $0.sourceTimeSeconds) }
            .sorted()
    }
    var audioEnabled: Bool { plan.audio?.isEnabled != false }
    var hasTranscript: Bool { transcript?.segments.isEmpty == false }
    var captionsEnabled: Bool { plan.captions?.isEnabled == true }
    var captionSourceCues: [CaptionSourceCue] {
        plan.captions?.customCues ?? automaticCaptionSourceCues
    }

    func selectSegment(_ id: UUID) {
        guard timeline.segments.contains(where: { $0.id == id }) else { return }
        selectedSegmentID = id
    }

    func split(atOutputTime outputTime: Double) {
        guard let position = timeline.position(atOutputTime: outputTime) else { return }
        mutate(timelineChanged: true) { plan in
            guard var timeline = plan.timeline,
                  let newID = timeline.split(
                    segmentID: position.segmentID,
                    atSourceTime: position.sourceTimeSeconds
                  ) else { return }
            plan.timeline = timeline
            selectedSegmentID = newID
        }
    }

    func trimSelectedStart(toOutputTime outputTime: Double) {
        guard let selectedSegmentID,
              let position = timeline.position(atOutputTime: outputTime),
              position.segmentID == selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.trimStart(
                of: selectedSegmentID,
                to: position.sourceTimeSeconds
            )
        }
    }

    func trimSelectedEnd(toOutputTime outputTime: Double) {
        guard let selectedSegmentID,
              let position = timeline.position(atOutputTime: outputTime),
              position.segmentID == selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.trimEnd(
                of: selectedSegmentID,
                to: position.sourceTimeSeconds
            )
        }
    }

    func removeSelectedSegment() {
        guard let selectedSegmentID, canRemoveSelectedSegment else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setEnabled(false, for: selectedSegmentID)
        }
        self.selectedSegmentID = activeSegments.first?.id
    }

    func setSelectedPlaybackRate(_ rate: Double) {
        guard let selectedSegmentID else { return }
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setPlaybackRate(rate, for: selectedSegmentID)
        }
    }

    func setSelectedTransitionKind(_ kind: VideoEditTransition.Kind) {
        guard let selectedSegmentID, canTransitionFromSelectedSegment else { return }
        let duration = selectedTransitionDuration
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setTransition(
                kind == .cut
                    ? nil
                    : VideoEditTransition(kind: kind, durationSeconds: duration),
                after: selectedSegmentID
            )
        }
    }

    func setSelectedTransitionDuration(_ duration: Double) {
        guard let selectedSegmentID,
              canTransitionFromSelectedSegment,
              selectedTransitionKind != .cut else { return }
        let kind = selectedTransitionKind
        mutate(timelineChanged: true) { plan in
            plan.timeline?.setTransition(
                VideoEditTransition(kind: kind, durationSeconds: duration),
                after: selectedSegmentID
            )
        }
    }

    func setCameraMotionEnabled(_ enabled: Bool) {
        mutate { $0.camera.mode = enabled ? "event-driven" : "off" }
    }

    func setZoomIntensity(_ value: Double) {
        mutate { $0.camera.zoomIntensity = min(max(value, 0), 1) }
    }

    func setCursorEnabled(_ enabled: Bool) {
        mutate { $0.cursor.isEnabled = enabled }
    }

    func setCursorScale(_ value: Double) {
        mutate { $0.cursor.scale = min(max(value, 0.5), 3) }
    }

    func setClickPulseEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.showsClickPulse = enabled
        }
    }

    func setCanvasEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.isEnabled = enabled
        }
    }

    func setCanvasMargin(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.margin = min(max(value, 0), 0.25)
        }
    }

    func setCanvasCornerRadius(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.cornerRadius = min(max(value, 0), 0.2)
        }
    }

    func setCanvasPreset(topHex: String, bottomHex: String) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.backgroundTopHex = topHex
            plan.canvas?.backgroundBottomHex = bottomHex
        }
    }

    func setPresenterEnabled(_ enabled: Bool) {
        guard hasCameraTrack else { return }
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.isEnabled = enabled
        }
    }

    func setPresenterShape(_ shape: AutoEditPlan.PresenterCamera.Shape) {
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.shape = shape
        }
    }

    func setPresenterAnchor(_ anchor: AutoEditPlan.PresenterCamera.Anchor) {
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.anchor = anchor
            plan.presenterCamera?.position = nil
        }
    }

    func setPresenterSize(_ value: Double) {
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.size = min(max(value, 0.08), 0.45)
        }
    }

    func setPresenterMirrored(_ mirrored: Bool) {
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.isMirrored = mirrored
        }
    }

    func setPresenterAvoidanceEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init() }
            plan.presenterCamera?.automaticallyAvoidsContent = enabled
        }
    }

    func setPresenterThumbnail(_ image: NSImage?) {
        presenterThumbnail = image
    }

    func presenterState(
        atOutputTime outputTime: Double,
        canvasAspectRatio: Double = 16.0 / 9.0
    ) -> PresenterCameraFrameState {
        var layout = plan.presenterCamera ?? .init()
        if presenterInteractionStartPlan != nil {
            layout.automaticallyAvoidsContent = false
        }
        let captionContext: (AutoEditPlan.Captions, Double)? = {
            guard let transcript,
                  let captions = plan.captions,
                  captions.isEnabled else { return nil }
            let cues = cachedCaptionCues(
                transcript: transcript,
                configuration: captions
            )
            let amount = CaptionCuePlanner.avoidanceAmount(at: outputTime, in: cues)
            return amount > 0.001 ? (captions, amount) : nil
        }()
        return PresenterCameraPlacementPlanner.state(
            atSourceTime: sourceTime(atOutputTime: outputTime),
            layout: layout,
            cameraKeyframes: EffectTimeline.effectiveCameraKeyframes(for: plan.camera),
            captions: captionContext?.0,
            captionAvoidanceAmount: captionContext?.1 ?? 0,
            canvasAspectRatio: canvasAspectRatio
        )
    }

    func hasPresenterKeyframe(nearOutputTime outputTime: Double) -> Bool {
        guard let layout = plan.presenterCamera else { return false }
        return nearestPresenterKeyframeIndex(
            in: layout,
            sourceTime: sourceTime(atOutputTime: outputTime)
        ) != nil
    }

    func upsertPresenterKeyframe(atOutputTime outputTime: Double) {
        guard hasCameraTrack else { return }
        let sourceTime = sourceTime(atOutputTime: outputTime)
        let state = presenterState(atOutputTime: outputTime)
        mutate { plan in
            if plan.presenterCamera == nil { plan.presenterCamera = .init(isEnabled: true) }
            guard var presenter = plan.presenterCamera else { return }
            let existingIndex = nearestPresenterKeyframeIndex(
                in: presenter,
                sourceTime: sourceTime
            )
            let storedTime = existingIndex.map {
                presenter.keyframes[$0].sourceTimeSeconds
            } ?? sourceTime
            let easing = existingIndex.map {
                presenter.keyframes[$0].easing
            } ?? "spring-gentle"
            let keyframe = AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: storedTime,
                center: state.center,
                size: state.size,
                easing: easing
            )
            if let existingIndex {
                presenter.keyframes[existingIndex] = keyframe
            } else {
                presenter.keyframes.append(keyframe)
            }
            presenter.keyframes.sort { $0.sourceTimeSeconds < $1.sourceTimeSeconds }
            plan.presenterCamera = presenter
        }
    }

    func removePresenterKeyframe(nearOutputTime outputTime: Double) {
        let sourceTime = sourceTime(atOutputTime: outputTime)
        guard let presenter = plan.presenterCamera,
              let index = nearestPresenterKeyframeIndex(
                  in: presenter,
                  sourceTime: sourceTime
              ) else { return }
        mutate { plan in
            plan.presenterCamera?.keyframes.remove(at: index)
        }
    }

    func presenterKeyframeEasing(nearOutputTime outputTime: Double) -> String? {
        guard let presenter = plan.presenterCamera,
              let index = nearestPresenterKeyframeIndex(
                  in: presenter,
                  sourceTime: sourceTime(atOutputTime: outputTime)
              ) else { return nil }
        return presenter.keyframes[index].easing
    }

    func setPresenterKeyframeEasing(_ easing: String, atOutputTime outputTime: Double) {
        let sourceTime = sourceTime(atOutputTime: outputTime)
        guard let presenter = plan.presenterCamera,
              let index = nearestPresenterKeyframeIndex(
                  in: presenter,
                  sourceTime: sourceTime
              ) else { return }
        mutate { plan in
            guard let current = plan.presenterCamera?.keyframes[index] else { return }
            plan.presenterCamera?.keyframes[index] = AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: current.sourceTimeSeconds,
                center: current.center,
                size: current.size,
                easing: easing
            )
        }
    }

    func previousPresenterKeyframeOutputTime(before outputTime: Double) -> Double? {
        presenterKeyframeOutputTimes.last {
            $0 < outputTime - 0.05
        }
    }

    func nextPresenterKeyframeOutputTime(after outputTime: Double) -> Double? {
        presenterKeyframeOutputTimes.first {
            $0 > outputTime + 0.05
        }
    }

    func beginPresenterInteraction() {
        guard hasCameraTrack,
              presenterEnabled,
              presenterInteractionStartPlan == nil else { return }
        presenterInteractionStartPlan = plan
    }

    func updatePresenterInteraction(
        center: TracePoint,
        size: Double,
        atOutputTime outputTime: Double
    ) {
        guard hasCameraTrack, presenterEnabled else { return }
        if presenterInteractionStartPlan == nil { beginPresenterInteraction() }
        let sourceTime = sourceTime(atOutputTime: outputTime)
        let normalized = AutoEditPlan.PresenterCameraKeyframe(
            sourceTimeSeconds: sourceTime,
            center: center,
            size: size
        )
        var updated = plan
        guard var presenter = updated.presenterCamera else { return }
        if let index = nearestPresenterKeyframeIndex(
            in: presenter,
            sourceTime: sourceTime
        ) {
            let existing = presenter.keyframes[index]
            presenter.keyframes[index] = AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: existing.sourceTimeSeconds,
                center: normalized.center,
                size: normalized.size,
                easing: existing.easing
            )
        } else {
            presenter.position = normalized.center
            presenter.size = normalized.size
        }
        updated.presenterCamera = presenter
        guard updated != plan else { return }
        plan = updated
        isDirty = plan != savedPlan
    }

    func endPresenterInteraction() {
        guard let start = presenterInteractionStartPlan else { return }
        presenterInteractionStartPlan = nil
        guard start != plan else { return }
        undoHistory.append(start)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        isDirty = plan != savedPlan
    }

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

    func setDuckingEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.audio == nil { plan.audio = .init() }
            plan.audio?.ducksSystemUnderNarration = enabled
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

    func setCaptionCueText(_ text: String, at index: Int) {
        guard transcript != nil else { return }
        let displayedCues = captionSourceCues
        guard displayedCues.indices.contains(index) else { return }
        let displayedCue = displayedCues[index]
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            guard var captions = plan.captions else { return }
            if captions.customCues == nil {
                captions.customCues = automaticCaptionSourceCues
            }
            guard let customIndex = captions.customCues?.firstIndex(of: displayedCue) else {
                return
            }
            captions.customCues?[customIndex].text = text
            plan.captions = captions
        }
    }

    func restoreAutomaticCaptionText() {
        guard plan.captions?.customCues != nil else { return }
        mutate { $0.captions?.customCues = nil }
    }

    func undo() {
        endPresenterInteraction()
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(plan)
        plan = previous
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func redo() {
        endPresenterInteraction()
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(plan)
        plan = next
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func resetToAutomaticPlan() {
        endPresenterInteraction()
        guard plan != initialPlan else { return }
        undoHistory.append(plan)
        redoHistory.removeAll()
        plan = initialPlan
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func markSaved() {
        endPresenterInteraction()
        savedPlan = plan
        isDirty = false
    }

    func beginProcessing() {
        isProcessing = true
    }

    func endProcessing() {
        isProcessing = false
    }

    private func mutate(
        timelineChanged: Bool = false,
        _ mutation: (inout AutoEditPlan) -> Void
    ) {
        endPresenterInteraction()
        var updated = plan
        mutation(&updated)
        guard updated != plan else { return }
        undoHistory.append(plan)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        plan = updated
        normalizeSelection()
        isDirty = plan != savedPlan
        if timelineChanged { onTimelineChanged?(timeline) }
    }

    private func normalizeSelection() {
        if let selectedSegmentID,
           activeSegments.contains(where: { $0.id == selectedSegmentID }) {
            return
        }
        selectedSegmentID = activeSegments.first?.id
    }

    private func sourceTime(atOutputTime outputTime: Double) -> Double {
        timeline.position(atOutputTime: outputTime)?.sourceTimeSeconds
            ?? min(max(outputTime.isFinite ? outputTime : 0, 0), sourceDurationSeconds)
    }

    private func cachedCaptionCues(
        transcript: TranscriptDocument,
        configuration: AutoEditPlan.Captions
    ) -> [CaptionCue] {
        let timeline = timeline
        if let cache = captionPlacementCache,
           cache.configuration == configuration,
           cache.timeline == timeline {
            return cache.cues
        }
        let cues = CaptionCuePlanner.cues(
            transcript: transcript,
            configuration: configuration,
            timeline: timeline
        )
        captionPlacementCache = (configuration, timeline, cues)
        return cues
    }

    private func nearestPresenterKeyframeIndex(
        in presenter: AutoEditPlan.PresenterCamera,
        sourceTime: Double,
        tolerance: Double = 0.05
    ) -> Int? {
        presenter.keyframes.enumerated()
            .filter { abs($0.element.sourceTimeSeconds - sourceTime) <= tolerance }
            .min { lhs, rhs in
                abs(lhs.element.sourceTimeSeconds - sourceTime)
                    < abs(rhs.element.sourceTimeSeconds - sourceTime)
            }?
            .offset
    }
}
