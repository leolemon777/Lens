import AppKit
import Foundation
import LensCore

@MainActor
final class VideoEditorModel: ObservableObject {
    struct VideoAnnotationOutputBand: Identifiable {
        let annotationID: UUID
        let rangeIndex: Int
        let range: VideoEditTimeRange

        var id: String { "\(annotationID.uuidString)-\(rangeIndex)" }
    }

    @Published var plan: AutoEditPlan
    @Published var selectedSegmentID: UUID?
    @Published private(set) var isDirty = false
    /// True once the latest edit plan has reached disk. This is intentionally
    /// separate from `isDirty`: a plan can be persisted while its renderer is
    /// still producing the matching preview.
    @Published private(set) var isPlanPersisted = true
    @Published private(set) var isProcessing = false
    @Published private(set) var processingProgress: Double?
    @Published var isRegeneratingCamera = false
    @Published var presenterThumbnail: NSImage?
    @Published var isVideoAnnotationEditing = false
    @Published var isVideoAnnotationSelectionMode = false
    @Published var selectedVideoAnnotationID: UUID?
    @Published var videoAnnotationDraft: ScreenshotAnnotation?
    @Published var selectedVideoAnnotationTool: ScreenshotAnnotationKind = .arrow
    @Published var selectedVideoAnnotationColor: LensColor = .red
    @Published var videoAnnotationTextDraft = "重点"
    @Published var defaultVideoAnnotationDurationSeconds = 2.0
    @Published var selectedCaptionCueIndex: Int?
    @Published var isManualCameraFocusEditing = false
    @Published var manualCameraScale = 1.80
    @Published var manualCameraHoldSeconds = 1.20

    let sourceDurationSeconds: Double
    let hasCameraTrack: Bool
    let hasMicrophoneTrack: Bool
    let transcript: TranscriptDocument?
    let microphoneURL: URL?
    let keyboardEventsURL: URL?
    var onTimelineChanged: ((VideoEditTimeline) -> Void)?

    let initialPlan: AutoEditPlan
    var savedPlan: AutoEditPlan
    var persistedPlan: AutoEditPlan
    let automaticCaptionSourceCues: [CaptionSourceCue]
    var undoHistory: [AutoEditPlan] = []
    var redoHistory: [AutoEditPlan] = []
    /// Slider drags update the live preview on every tick, but should be one
    /// undoable edit rather than dozens of full-plan snapshots.
    var continuousEditBaseline: AutoEditPlan?
    var presenterInteractionStartPlan: AutoEditPlan?
    var videoAnnotationDraftID = UUID()
    var videoAnnotationDraftPath: [LensPoint] = []
    var videoAnnotationInteractionActive = false
    var activeVideoAnnotationTransform: ActiveVideoAnnotationTransform?
    var captionPlacementCache: (
        configuration: AutoEditPlan.Captions,
        timeline: VideoEditTimeline,
        cues: [CaptionCue]
    )?
    var preAuditionAudio: AutoEditPlan.Audio?

    struct ActiveVideoAnnotationTransform {
        enum Operation {
            case move
            case resize(ScreenshotAnnotationResizeHandle)
        }

        let baseline: AutoEditPlan
        let original: VideoAnnotation
        let startPoint: LensPoint
        let operation: Operation
    }

    init(
        plan requestedPlan: AutoEditPlan,
        sourceDurationSeconds: Double,
        hasCameraTrack: Bool,
        hasMicrophoneTrack: Bool = false,
        transcript: TranscriptDocument? = nil,
        microphoneURL: URL? = nil,
        keyboardEventsURL: URL? = nil
    ) {
        let duration = max(sourceDurationSeconds.isFinite ? sourceDurationSeconds : 0, 0)
        var plan = requestedPlan
        plan.schemaVersion = AutoEditPlan.currentSchemaVersion
        plan.timeline = (plan.timeline ?? VideoEditTimeline(
            sourceDurationSeconds: duration
        )).normalized(sourceDurationSeconds: duration)
        plan.videoAnnotations = (plan.videoAnnotations ?? []).compactMap {
            $0.normalized(sourceDurationSeconds: duration)
        }
        if let customCues = plan.captions?.customCues {
            plan.captions?.customCues = CaptionCueEditor.normalized(
                customCues,
                sourceDurationSeconds: duration
            )
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
        persistedPlan = plan
        self.automaticCaptionSourceCues = automaticCaptionSourceCues
        self.sourceDurationSeconds = duration
        self.hasCameraTrack = hasCameraTrack
        self.hasMicrophoneTrack = hasMicrophoneTrack
        self.transcript = transcript
        self.microphoneURL = microphoneURL
        self.keyboardEventsURL = keyboardEventsURL
        selectedSegmentID = plan.timeline?.activeSegments.first?.id
        startNarrationTrimDetectionIfNeeded()
        hydrateKeystrokesIfNeeded()
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
    var manualCameraFocusCount: Int {
        plan.camera.keyframes.count { $0.reason == .manualFocus }
    }
    var manualCameraFocusOutputTimes: [Double] {
        plan.camera.keyframes
            .filter { $0.reason == .manualFocus }
            .flatMap { timeline.outputTimes(forSourceTime: $0.time) }
            .sorted()
    }
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
    var microphoneNoiseReductionEnabled: Bool {
        plan.audio?.reducesMicrophoneNoise == true
    }
    var loudnessNormalizationEnabled: Bool {
        plan.audio?.normalizesLoudness == true
    }
    var hasTranscript: Bool { transcript?.segments.isEmpty == false }
    var captionsEnabled: Bool { plan.captions?.isEnabled == true }
    var exportPreset: AutoEditPlan.Export.Preset {
        plan.export?.preset ?? .source
    }
    var captionSourceCues: [CaptionSourceCue] {
        plan.captions?.customCues ?? automaticCaptionSourceCues
    }
    var selectedCaptionCue: CaptionSourceCue? {
        guard let selectedCaptionCueIndex,
              captionSourceCues.indices.contains(selectedCaptionCueIndex) else { return nil }
        return captionSourceCues[selectedCaptionCueIndex]
    }
    var canMergeSelectedCaptionCueWithNext: Bool {
        guard let selectedCaptionCueIndex else { return false }
        return captionSourceCues.indices.contains(selectedCaptionCueIndex + 1)
    }
    var videoAnnotations: [VideoAnnotation] { plan.videoAnnotations ?? [] }
    var selectedVideoAnnotation: VideoAnnotation? {
        guard let selectedVideoAnnotationID else { return nil }
        return videoAnnotations.first { $0.id == selectedVideoAnnotationID }
    }
    var videoAnnotationOutputBands: [VideoAnnotationOutputBand] {
        videoAnnotations.flatMap { item in
            VideoAnnotationPlanner.outputRanges(for: item, timeline: timeline)
                .enumerated()
                .map { index, range in
                    VideoAnnotationOutputBand(
                        annotationID: item.id,
                        rangeIndex: index,
                        range: range
                    )
                }
        }
    }

    func visibleVideoAnnotations(
        atOutputTime outputTime: Double
    ) -> [(item: VideoAnnotation, opacity: Double)] {
        let contributions = timeline.sourceContributions(atOutputTime: outputTime)
        return videoAnnotations.compactMap { item in
            let isOnContributingSource = contributions.contains {
                $0.sourceTimeSeconds >= item.sourceStartSeconds
                    && $0.sourceTimeSeconds < item.sourceEndSeconds
            }
            let opacity = min(contributions.reduce(0) { partial, contribution in
                partial + item.opacity(atSourceTime: contribution.sourceTimeSeconds)
                    * contribution.weight
            }, 1)
            guard opacity > 0.000_1
                    || item.id == selectedVideoAnnotationID && isOnContributingSource else {
                return nil
            }
            return (item, max(
                opacity,
                item.id == selectedVideoAnnotationID ? 0.22 : 0.001
            ))
        }
    }

    @Published var narrationTrimDetectionState: NarrationTrimDetectionState = .ready
    var narrationTrimDetectionRevision = 0

    var narrationTrimSuggestions: [NarrationTrimSuggestion] {
        plan.narrationTrims ?? []
    }

    var pendingNarrationTrims: [NarrationTrimSuggestion] {
        narrationTrimSuggestions.filter { $0.status == .pending }
    }

    /// Total source time the accepted (and pending) suggestions would remove.
    var narrationTrimCandidateSeconds: Double {
        narrationTrimSuggestions
            .filter { $0.status != .rejected }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// Output times a suggestion maps to under the current timeline, used to
    /// seek the playhead when a row is inspected.

    func undo() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        endContinuousEdit()
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(plan)
        plan = previous
        normalizeSelection()
        syncChangeState()
        onTimelineChanged?(timeline)
    }

    func redo() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        endContinuousEdit()
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(plan)
        plan = next
        normalizeSelection()
        syncChangeState()
        onTimelineChanged?(timeline)
    }

    func resetToAutomaticPlan() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        endContinuousEdit()
        cancelVideoAnnotationDraft()
        guard plan != initialPlan else { return }
        undoHistory.append(plan)
        redoHistory.removeAll()
        plan = initialPlan
        normalizeSelection()
        syncChangeState()
        onTimelineChanged?(timeline)
    }

    /// Records the exact plan that reached disk and a completed preview. The
    /// editor may continue accepting changes while that preview is rendering;
    /// those newer changes must remain dirty instead of being falsely marked
    /// as saved when an older render finishes.
    func markSaved(_ persistedPlan: AutoEditPlan? = nil) {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        endContinuousEdit()
        let completedPlan = persistedPlan ?? plan
        self.persistedPlan = completedPlan
        savedPlan = completedPlan
        syncChangeState()
    }

    /// Marks a plan as safely written before its preview finishes rendering.
    /// Closing the editor after this point cannot lose the user's changes,
    /// even though `isDirty` remains true until the matching preview arrives.
    func markPlanPersisted(_ persistedPlan: AutoEditPlan) {
        self.persistedPlan = persistedPlan
        syncChangeState()
    }

    func beginProcessing() {
        isProcessing = true
        processingProgress = 0
    }

    func updateProcessingProgress(_ fraction: Double) {
        guard isProcessing else { return }
        processingProgress = min(max(fraction, 0), 1)
    }

    func endProcessing() {
        isProcessing = false
        processingProgress = nil
    }

    /// A preview rendered in the background may arrive after the editor has
    /// already accepted newer input. Only the exact, untouched plan is safe to
    /// adopt without flashing stale effects over the user's work.
    func canAdoptBackgroundPreview(renderedPlan: AutoEditPlan) -> Bool {
        !isDirty
            && !isProcessing
            && !isRegeneratingCamera
            && plan == renderedPlan
    }

    func mutate(
        timelineChanged: Bool = false,
        _ mutation: (inout AutoEditPlan) -> Void
    ) {
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        var updated = plan
        mutation(&updated)
        guard updated != plan else { return }
        if continuousEditBaseline == nil {
            undoHistory.append(plan)
            if undoHistory.count > 80 { undoHistory.removeFirst() }
        }
        redoHistory.removeAll()
        plan = updated
        normalizeSelection()
        syncChangeState()
        if timelineChanged { onTimelineChanged?(timeline) }
    }

    func syncChangeState() {
        isDirty = plan != savedPlan
        isPlanPersisted = plan == persistedPlan
    }

    static func cameraReasonPriority(
        _ reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> Int {
        switch reason {
        case .baseline: 0
        case .clickFocus: 1
        case .pointerFollow: 2
        case .clickHold: 3
        case .returnToOverview: 4
        case .manualAnchor: 5
        case .manualFocus: 6
        case .manualHold: 7
        case .manualReturn: 8
        }
    }

    static func isManualCameraReason(
        _ reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> Bool {
        switch reason {
        case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
            true
        default:
            false
        }
    }

    func normalizeSelection() {
        if selectedSegmentID == nil
            || !activeSegments.contains(where: { $0.id == selectedSegmentID }) {
            selectedSegmentID = activeSegments.first?.id
        }
        if let selectedVideoAnnotationID,
           !videoAnnotations.contains(where: { $0.id == selectedVideoAnnotationID }) {
            self.selectedVideoAnnotationID = nil
        }
        if let selectedCaptionCueIndex {
            self.selectedCaptionCueIndex = captionSourceCues.isEmpty
                ? nil
                : min(max(selectedCaptionCueIndex, 0), captionSourceCues.count - 1)
        }
    }

    @discardableResult
    func mutateCaptionCues(
        _ mutation: ([CaptionSourceCue]) -> [CaptionSourceCue]?
    ) -> Bool {
        guard transcript != nil else { return false }
        var changed = false
        mutate { plan in
            if plan.captions == nil { plan.captions = .init() }
            guard var captions = plan.captions else { return }
            let cues = CaptionCueEditor.normalized(
                captions.customCues ?? automaticCaptionSourceCues,
                sourceDurationSeconds: sourceDurationSeconds
            )
            guard let edited = mutation(cues) else { return }
            let normalized = CaptionCueEditor.normalized(
                edited,
                sourceDurationSeconds: sourceDurationSeconds
            )
            guard normalized != cues || captions.customCues == nil else { return }
            captions.customCues = normalized
            plan.captions = captions
            changed = true
        }
        return changed
    }

    func sourceTime(atOutputTime outputTime: Double) -> Double {
        timeline.position(atOutputTime: outputTime)?.sourceTimeSeconds
            ?? min(max(outputTime.isFinite ? outputTime : 0, 0), sourceDurationSeconds)
    }

    func makeVideoAnnotation(
        id: UUID,
        start: LensPoint,
        end: LensPoint
    ) -> ScreenshotAnnotation? {
        let deltaX = abs(end.x - start.x)
        let deltaY = abs(end.y - start.y)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let minimumExtent = 0.006
        let bounds: LensRect
        if (selectedVideoAnnotationTool == .text || selectedVideoAnnotationTool == .step),
           deltaX < minimumExtent, deltaY < minimumExtent {
            let defaultSize = selectedVideoAnnotationTool == .step ? 0.075 : 0.08
            let defaultWidth = selectedVideoAnnotationTool == .step ? defaultSize : 0.26
            bounds = LensRect(
                x: min(max(
                    start.x - (selectedVideoAnnotationTool == .step ? defaultSize / 2 : 0),
                    0
                ), 1 - defaultWidth),
                y: min(max(
                    start.y - (selectedVideoAnnotationTool == .step ? defaultSize / 2 : 0),
                    0
                ), 1 - defaultSize),
                width: defaultWidth,
                height: defaultSize
            )
        } else {
            guard deltaX >= minimumExtent || deltaY >= minimumExtent else { return nil }
            bounds = ScreenshotAnnotationGeometry.bounds(
                from: start,
                to: end,
                minimumExtent: minimumExtent
            )
        }
        if selectedVideoAnnotationTool == .arrow, distance < 0.012 { return nil }
        let fillColor: LensColor? = switch selectedVideoAnnotationTool {
        case .rectangle, .ellipse:
            LensColor(
                red: selectedVideoAnnotationColor.red,
                green: selectedVideoAnnotationColor.green,
                blue: selectedVideoAnnotationColor.blue,
                alpha: 0.10
            )
        case .highlight:
            LensColor(
                red: selectedVideoAnnotationColor.red,
                green: selectedVideoAnnotationColor.green,
                blue: selectedVideoAnnotationColor.blue,
                alpha: 0.28
            )
        case .step:
            selectedVideoAnnotationColor
        default:
            nil
        }
        let annotationText: String? = switch selectedVideoAnnotationTool {
        case .text:
            normalizedVideoAnnotationTextDraft
        case .step:
            String(nextVideoAnnotationStepNumber)
        default:
            nil
        }
        return ScreenshotAnnotation(
            id: id,
            kind: selectedVideoAnnotationTool,
            bounds: bounds,
            start: selectedVideoAnnotationTool == .arrow ? start : nil,
            end: selectedVideoAnnotationTool == .arrow ? end : nil,
            text: annotationText,
            style: ScreenshotAnnotationStyle(
                lineWidth: selectedVideoAnnotationTool == .highlight ? 0 : 0.008,
                fontSize: 0.052,
                color: selectedVideoAnnotationColor,
                fillColor: fillColor,
                intensity: selectedVideoAnnotationTool == .pixelate ? 0.055 : 0.035
            )
        )
    }

    func makeVideoFreehandAnnotation(
        id: UUID,
        points: [LensPoint]
    ) -> ScreenshotAnnotation? {
        let simplified = simplifyVideoAnnotationPath(points, minimumDistance: 0.0015)
        guard simplified.count >= 2,
              let bounds = ScreenshotAnnotationGeometry.bounds(for: simplified),
              let first = simplified.first,
              let last = simplified.last,
              hypot(last.x - first.x, last.y - first.y) >= 0.006
                || videoAnnotationPathLength(simplified) >= 0.012 else {
            return nil
        }
        return ScreenshotAnnotation(
            id: id,
            kind: .freehand,
            bounds: bounds,
            points: simplified,
            style: ScreenshotAnnotationStyle(
                lineWidth: 0.008,
                color: selectedVideoAnnotationColor
            )
        )
    }

    var nextVideoAnnotationStepNumber: Int {
        videoAnnotations
            .filter { $0.annotation.kind == .step }
            .compactMap { $0.annotation.text.flatMap(Int.init) }
            .max()
            .map { $0 + 1 }
            ?? 1
    }

    var normalizedVideoAnnotationTextDraft: String {
        let value = videoAnnotationTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "文字" : value
    }

    func appendVideoAnnotationDraftPoint(_ point: LensPoint) {
        guard let last = videoAnnotationDraftPath.last else {
            videoAnnotationDraftPath.append(point)
            return
        }
        guard hypot(point.x - last.x, point.y - last.y) >= 0.0008 else { return }
        videoAnnotationDraftPath.append(point)
    }

    func simplifyVideoAnnotationPath(
        _ points: [LensPoint],
        minimumDistance: Double
    ) -> [LensPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst() {
            guard let last = result.last else { continue }
            if hypot(point.x - last.x, point.y - last.y) >= minimumDistance {
                result.append(point)
            }
        }
        if let last = points.last, result.last != last { result.append(last) }
        return result
    }

    func videoAnnotationPathLength(_ points: [LensPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    func clamped(_ point: LensPoint) -> LensPoint {
        LensPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    func cachedCaptionCues(
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

    func nearestPresenterKeyframeIndex(
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
