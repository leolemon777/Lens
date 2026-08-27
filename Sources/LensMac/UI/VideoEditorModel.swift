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

    @Published private(set) var plan: AutoEditPlan
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var isDirty = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isRegeneratingCamera = false
    @Published private(set) var presenterThumbnail: NSImage?
    @Published private(set) var isVideoAnnotationEditing = false
    @Published private(set) var isVideoAnnotationSelectionMode = false
    @Published private(set) var selectedVideoAnnotationID: UUID?
    @Published private(set) var videoAnnotationDraft: ScreenshotAnnotation?
    @Published var selectedVideoAnnotationTool: ScreenshotAnnotationKind = .arrow
    @Published var selectedVideoAnnotationColor: LensColor = .red
    @Published var videoAnnotationTextDraft = "重点"
    @Published var defaultVideoAnnotationDurationSeconds = 2.0
    @Published private(set) var selectedCaptionCueIndex: Int?
    @Published private(set) var isManualCameraFocusEditing = false
    @Published var manualCameraScale = 1.80
    @Published var manualCameraHoldSeconds = 1.20

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
    private var videoAnnotationDraftID = UUID()
    private var videoAnnotationDraftPath: [LensPoint] = []
    private var videoAnnotationInteractionActive = false
    private var activeVideoAnnotationTransform: ActiveVideoAnnotationTransform?
    private var captionPlacementCache: (
        configuration: AutoEditPlan.Captions,
        timeline: VideoEditTimeline,
        cues: [CaptionCue]
    )?

    private struct ActiveVideoAnnotationTransform {
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
        transcript: TranscriptDocument? = nil
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

    func setAutomaticZoomScale(_ value: Double) {
        let requestedScale = min(max(value.isFinite ? value : 1.60, 1), 3)
        mutate { plan in
            let effective = EffectTimeline.effectiveCameraKeyframes(for: plan.camera)
            let automaticPeak = effective.enumerated().reduce(1.0) { peak, item in
                let (index, keyframe) = item
                guard !Self.isManualCameraReason(keyframe.reason),
                      plan.camera.keyframes.indices.contains(index) else { return peak }
                return max(peak, keyframe.scale)
            }
            plan.camera.keyframes = plan.camera.keyframes.enumerated().map { index, keyframe in
                guard !Self.isManualCameraReason(keyframe.reason),
                      effective.indices.contains(index),
                      automaticPeak > 1.000_1 else { return keyframe }
                let renderedScale = effective[index].scale
                let relativeAmount = min(max(
                    (renderedScale - 1) / (automaticPeak - 1),
                    0
                ), 1)
                let scale = 1 + (requestedScale - 1) * relativeAmount
                let visibleHalf = 0.5 / scale
                return AutoEditPlan.CameraKeyframe(
                    time: keyframe.time,
                    scale: scale,
                    center: LensPoint(
                        x: min(max(keyframe.center.x, visibleHalf), 1 - visibleHalf),
                        y: min(max(keyframe.center.y, visibleHalf), 1 - visibleHalf)
                    ),
                    easing: keyframe.easing,
                    reason: keyframe.reason
                )
            }
            plan.camera.zoomScale = requestedScale
            plan.camera.zoomIntensity = 0.42
        }
    }

    func setAutomaticCameraGenerationStrength(
        _ strength: AutoEditPlan.Camera.GenerationStrength
    ) {
        mutate { $0.camera.generationStrength = strength }
    }

    func setCameraMotionBlurStrength(_ value: Double) {
        mutate {
            $0.camera.motionBlurStrength = min(max(value.isFinite ? value : 0, 0), 1)
        }
    }

    func setClickToZoomEnabled(_ enabled: Bool) {
        mutate { $0.camera.clickToZoom = enabled }
    }

    func setCameraFollowPointerEnabled(_ enabled: Bool) {
        mutate { $0.camera.followPointer = enabled }
    }

    func replaceAutomaticCameraKeyframes(
        with keyframes: [AutoEditPlan.CameraKeyframe]
    ) {
        let manual = plan.camera.keyframes.filter { keyframe in
            switch keyframe.reason {
            case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
                true
            default:
                false
            }
        }
        mutate { plan in
            if plan.camera.zoomScale == nil {
                plan.camera.zoomScale = plan.camera.resolvedZoomScale
                plan.camera.zoomIntensity = 0.42
            }
            plan.camera.keyframes = (keyframes + manual).sorted { lhs, rhs in
                if lhs.time != rhs.time { return lhs.time < rhs.time }
                return Self.cameraReasonPriority(lhs.reason)
                    < Self.cameraReasonPriority(rhs.reason)
            }
        }
    }

    func beginRegeneratingCamera() {
        isRegeneratingCamera = true
    }

    func endRegeneratingCamera() {
        isRegeneratingCamera = false
    }

    func activateManualCameraFocusEditing() {
        finishVideoAnnotationEditing()
        isManualCameraFocusEditing = true
    }

    func cancelManualCameraFocusEditing() {
        isManualCameraFocusEditing = false
    }

    @discardableResult
    func addManualCameraFocus(
        center: LensPoint,
        atOutputTime outputTime: Double
    ) -> Bool {
        guard isManualCameraFocusEditing else { return false }
        let sourceTime = sourceTime(atOutputTime: outputTime)
        let previousPlan = plan
        let editor = ManualCameraEditor(configuration: .init(
            holdDuration: min(max(manualCameraHoldSeconds, 0.20), 8)
        ))
        mutate { plan in
            plan.camera = editor.insertingFocus(
                at: sourceTime,
                center: center,
                scale: min(max(manualCameraScale, 1), 3),
                duration: sourceDurationSeconds,
                into: plan.camera
            )
        }
        isManualCameraFocusEditing = false
        return plan != previousPlan
    }

    func clearManualCameraFocuses() {
        guard manualCameraFocusCount > 0 else { return }
        mutate { plan in
            plan.camera = ManualCameraEditor().removingManualKeyframes(from: plan.camera)
        }
        isManualCameraFocusEditing = false
    }

    func setCursorEnabled(_ enabled: Bool) {
        mutate { $0.cursor.isEnabled = enabled }
    }

    func setCursorAppearance(_ appearance: AutoEditPlan.Cursor.Appearance) {
        mutate { $0.cursor.appearance = appearance }
    }

    func setCursorAccentColorHex(_ value: String) {
        mutate { plan in
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "# ")
            ).uppercased()
            plan.cursor.accentColorHex = if trimmed.count == 6,
                                            UInt32(trimmed, radix: 16) != nil {
                "#\(trimmed)"
            } else {
                "#5BD6FF"
            }
        }
    }

    func setCursorMotionEffect(_ effect: AutoEditPlan.Cursor.MotionEffect) {
        mutate { $0.cursor.motionEffect = effect }
    }

    func setCursorMotionEffectStrength(_ value: Double) {
        mutate { plan in
            plan.cursor.motionEffectStrength = min(max(
                value.isFinite ? value : 0.42,
                0.1
            ), 1)
        }
    }

    func setCursorScale(_ value: Double) {
        mutate { $0.cursor.scale = min(max(value, 0.5), 3) }
    }

    func setCursorSmoothingWindowMilliseconds(_ value: Double) {
        mutate { plan in
            let milliseconds = min(max(value.isFinite ? value : 0, 0), 160)
            plan.cursor.smoothingWindowMilliseconds = milliseconds
            plan.cursor.smoothing = min(milliseconds / 80, 1)
        }
    }

    func setCursorHidesWhenIdle(_ enabled: Bool) {
        mutate { $0.cursor.hidesWhenIdle = enabled }
    }

    func setClickPulseEnabled(_ enabled: Bool) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.showsClickPulse = enabled
        }
    }

    func setClickEffect(_ effect: AutoEditPlan.Interaction.ClickEffect) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickEffect = effect
        }
    }

    func setClickEffectStrength(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickEffectStrength = min(max(
                value.isFinite ? value : 1,
                0.1
            ), 1)
        }
    }

    func setClickPulseScale(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickPulseScale = min(max(
                value.isFinite ? value : 1.25,
                0.5
            ), 3)
        }
    }

    func setClickPulseDuration(_ value: Double) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            plan.interaction?.clickPulseDuration = min(max(
                value.isFinite ? value : 0.62,
                0.15
            ), 1.5)
        }
    }

    func setClickPulseColorHex(_ value: String) {
        mutate { plan in
            if plan.interaction == nil { plan.interaction = .init() }
            let normalized = AutoEditPlan.Interaction(
                clickPulseColorHex: value
            ).clickPulseColorHex
            plan.interaction?.clickPulseColorHex = normalized
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

    func setCanvasShadowOpacity(_ value: Double) {
        mutate { plan in
            if plan.canvas == nil { plan.canvas = .init() }
            plan.canvas?.shadowOpacity = min(max(
                value.isFinite ? value : 0.24,
                0
            ), 1)
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
        center: LensPoint,
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

    func activateVideoAnnotationSelection() {
        cancelManualCameraFocusEditing()
        cancelVideoAnnotationDraft()
        cancelVideoAnnotationInteraction()
        isVideoAnnotationEditing = true
        isVideoAnnotationSelectionMode = true
    }

    func selectVideoAnnotation(_ id: UUID) {
        guard videoAnnotations.contains(where: { $0.id == id }) else { return }
        activateVideoAnnotationSelection()
        selectedVideoAnnotationID = id
        if let selected = selectedVideoAnnotation {
            selectedVideoAnnotationColor = selected.annotation.style.color
            if selected.annotation.kind == .text, let text = selected.annotation.text {
                videoAnnotationTextDraft = text
            }
            defaultVideoAnnotationDurationSeconds = selected.sourceDurationSeconds
        }
    }

    func activateVideoAnnotationTool(_ tool: ScreenshotAnnotationKind) {
        cancelManualCameraFocusEditing()
        cancelVideoAnnotationDraft()
        cancelVideoAnnotationInteraction()
        selectedVideoAnnotationTool = tool
        isVideoAnnotationEditing = true
        isVideoAnnotationSelectionMode = false
        selectedVideoAnnotationID = nil
    }

    func finishVideoAnnotationEditing() {
        cancelVideoAnnotationDraft()
        endVideoAnnotationInteraction()
        isVideoAnnotationEditing = false
    }

    func updateVideoAnnotationDraft(start: LensPoint, end: LensPoint) {
        guard isVideoAnnotationEditing, !isVideoAnnotationSelectionMode else { return }
        if selectedVideoAnnotationTool == .freehand {
            if videoAnnotationDraftPath.isEmpty {
                appendVideoAnnotationDraftPoint(clamped(start))
            }
            appendVideoAnnotationDraftPoint(clamped(end))
            videoAnnotationDraft = makeVideoFreehandAnnotation(
                id: videoAnnotationDraftID,
                points: videoAnnotationDraftPath
            )
        } else {
            videoAnnotationDraft = makeVideoAnnotation(
                id: videoAnnotationDraftID,
                start: clamped(start),
                end: clamped(end)
            )
        }
    }

    @discardableResult
    func commitVideoAnnotationDraft(
        start: LensPoint,
        end: LensPoint,
        atOutputTime outputTime: Double
    ) -> Bool {
        guard isVideoAnnotationEditing,
              !isVideoAnnotationSelectionMode,
              sourceDurationSeconds >= VideoEditTimeline.minimumSegmentDurationSeconds else {
            cancelVideoAnnotationDraft()
            return false
        }
        let startPoint = clamped(start)
        let endPoint = clamped(end)
        let annotation: ScreenshotAnnotation?
        if selectedVideoAnnotationTool == .freehand {
            if videoAnnotationDraftPath.isEmpty {
                appendVideoAnnotationDraftPoint(startPoint)
            }
            appendVideoAnnotationDraftPoint(endPoint)
            annotation = makeVideoFreehandAnnotation(
                id: videoAnnotationDraftID,
                points: videoAnnotationDraftPath
            )
        } else {
            annotation = makeVideoAnnotation(
                id: videoAnnotationDraftID,
                start: startPoint,
                end: endPoint
            )
        }
        guard let annotation else {
            cancelVideoAnnotationDraft()
            return false
        }

        let minimumDuration = VideoEditTimeline.minimumSegmentDurationSeconds
        let sourceStart = min(
            max(sourceTime(atOutputTime: outputTime), 0),
            max(sourceDurationSeconds - minimumDuration, 0)
        )
        let requestedDuration = min(max(
            defaultVideoAnnotationDurationSeconds,
            minimumDuration
        ), 30)
        let sourceEnd = min(
            max(sourceStart + requestedDuration, sourceStart + minimumDuration),
            sourceDurationSeconds
        )
        let item = VideoAnnotation(
            annotation: annotation,
            sourceStartSeconds: sourceStart,
            sourceEndSeconds: sourceEnd
        )
        mutate { plan in
            if plan.videoAnnotations == nil { plan.videoAnnotations = [] }
            plan.videoAnnotations?.append(item)
        }
        videoAnnotationDraft = nil
        videoAnnotationDraftID = UUID()
        videoAnnotationDraftPath.removeAll(keepingCapacity: true)
        return true
    }

    func cancelVideoAnnotationDraft() {
        videoAnnotationDraft = nil
        videoAnnotationDraftID = UUID()
        videoAnnotationDraftPath.removeAll(keepingCapacity: true)
    }

    func beginVideoAnnotationSelectionInteraction(
        at point: LensPoint,
        outputTime: Double,
        hitTolerance: Double,
        handleTolerance: Double
    ) {
        guard isVideoAnnotationEditing,
              isVideoAnnotationSelectionMode,
              !videoAnnotationInteractionActive else { return }
        videoAnnotationInteractionActive = true
        let point = clamped(point)
        let contributions = timeline.sourceContributions(atOutputTime: outputTime)
        let activeItems = videoAnnotations.filter {
            let item = $0
            return contributions.contains {
                $0.sourceTimeSeconds >= item.sourceStartSeconds
                    && $0.sourceTimeSeconds < item.sourceEndSeconds
            }
        }

        if let selected = selectedVideoAnnotation,
           activeItems.contains(where: { $0.id == selected.id }),
           let handle = ScreenshotAnnotationGeometry.resizeHandle(
               for: selected.annotation,
               at: point,
               tolerance: handleTolerance
           ) {
            activeVideoAnnotationTransform = ActiveVideoAnnotationTransform(
                baseline: plan,
                original: selected,
                startPoint: point,
                operation: .resize(handle)
            )
            return
        }

        guard let hitID = ScreenshotAnnotationGeometry.topmostAnnotationID(
            in: activeItems.map(\.annotation),
            at: point,
            tolerance: hitTolerance
        ), let hit = activeItems.first(where: { $0.id == hitID }) else {
            selectedVideoAnnotationID = nil
            activeVideoAnnotationTransform = nil
            return
        }
        selectedVideoAnnotationID = hitID
        selectedVideoAnnotationColor = hit.annotation.style.color
        if hit.annotation.kind == .text, let text = hit.annotation.text {
            videoAnnotationTextDraft = text
        }
        activeVideoAnnotationTransform = ActiveVideoAnnotationTransform(
            baseline: plan,
            original: hit,
            startPoint: point,
            operation: .move
        )
    }

    func updateVideoAnnotationSelectionInteraction(to point: LensPoint) {
        guard videoAnnotationInteractionActive,
              let activeVideoAnnotationTransform else { return }
        let annotation: ScreenshotAnnotation
        switch activeVideoAnnotationTransform.operation {
        case .move:
            annotation = ScreenshotAnnotationGeometry.moved(
                activeVideoAnnotationTransform.original.annotation,
                byX: clamped(point).x - activeVideoAnnotationTransform.startPoint.x,
                y: clamped(point).y - activeVideoAnnotationTransform.startPoint.y
            )
        case let .resize(handle):
            annotation = ScreenshotAnnotationGeometry.resized(
                activeVideoAnnotationTransform.original.annotation,
                handle: handle,
                to: clamped(point)
            )
        }
        var updated = plan
        guard let index = updated.videoAnnotations?.firstIndex(where: {
            $0.id == activeVideoAnnotationTransform.original.id
        }) else { return }
        updated.videoAnnotations?[index].annotation = annotation
        guard updated != plan else { return }
        plan = updated
        isDirty = plan != savedPlan
    }

    func endVideoAnnotationInteraction() {
        guard videoAnnotationInteractionActive else { return }
        videoAnnotationInteractionActive = false
        guard let activeVideoAnnotationTransform else { return }
        self.activeVideoAnnotationTransform = nil
        guard activeVideoAnnotationTransform.baseline != plan else { return }
        undoHistory.append(activeVideoAnnotationTransform.baseline)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        isDirty = plan != savedPlan
    }

    func cancelVideoAnnotationInteraction() {
        videoAnnotationInteractionActive = false
        guard let activeVideoAnnotationTransform else { return }
        plan = activeVideoAnnotationTransform.baseline
        self.activeVideoAnnotationTransform = nil
        isDirty = plan != savedPlan
    }

    func deleteSelectedVideoAnnotation() {
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            plan.videoAnnotations?.removeAll { $0.id == selectedVideoAnnotationID }
        }
        self.selectedVideoAnnotationID = nil
    }

    func setVideoAnnotationColor(_ color: LensColor) {
        selectedVideoAnnotationColor = color
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }) else { return }
            plan.videoAnnotations?[index].annotation.style.color = color
            if let fill = plan.videoAnnotations?[index].annotation.style.fillColor {
                plan.videoAnnotations?[index].annotation.style.fillColor = LensColor(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: fill.alpha
                )
            }
        }
    }

    func setSelectedVideoAnnotationDuration(_ duration: Double) {
        let value = min(max(
            duration.isFinite ? duration : 2,
            VideoEditTimeline.minimumSegmentDurationSeconds
        ), 30)
        defaultVideoAnnotationDurationSeconds = value
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }), let item = plan.videoAnnotations?[index] else { return }
            plan.videoAnnotations?[index].sourceEndSeconds = min(
                item.sourceStartSeconds + value,
                sourceDurationSeconds
            )
        }
    }

    func setSelectedVideoAnnotationFadeDuration(_ duration: Double) {
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }) else { return }
            plan.videoAnnotations?[index].fadeDurationSeconds = min(max(
                duration.isFinite ? duration : 0.16,
                0
            ), 1)
        }
    }

    func setSelectedVideoAnnotationLineWidth(_ value: Double) {
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }) else { return }
            plan.videoAnnotations?[index].annotation.style.lineWidth = min(max(value, 0.002), 0.04)
        }
    }

    func setSelectedVideoAnnotationIntensity(_ value: Double) {
        guard let selectedVideoAnnotationID else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }) else { return }
            plan.videoAnnotations?[index].annotation.style.intensity = min(max(value, 0.01), 0.12)
        }
    }

    func applyVideoAnnotationTextDraft() {
        let text = videoAnnotationTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedVideoAnnotationID, !text.isEmpty else { return }
        mutate { plan in
            guard let index = plan.videoAnnotations?.firstIndex(where: {
                $0.id == selectedVideoAnnotationID
            }), plan.videoAnnotations?[index].annotation.kind == .text else { return }
            plan.videoAnnotations?[index].annotation.text = text
        }
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

    func undo() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(plan)
        plan = previous
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func redo() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(plan)
        plan = next
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func resetToAutomaticPlan() {
        cancelManualCameraFocusEditing()
        endPresenterInteraction()
        endVideoAnnotationInteraction()
        cancelVideoAnnotationDraft()
        guard plan != initialPlan else { return }
        undoHistory.append(plan)
        redoHistory.removeAll()
        plan = initialPlan
        normalizeSelection()
        isDirty = plan != savedPlan
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
        let persistedPlan = persistedPlan ?? plan
        savedPlan = persistedPlan
        isDirty = plan != persistedPlan
    }

    func beginProcessing() {
        isProcessing = true
    }

    func endProcessing() {
        isProcessing = false
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

    private func mutate(
        timelineChanged: Bool = false,
        _ mutation: (inout AutoEditPlan) -> Void
    ) {
        endPresenterInteraction()
        endVideoAnnotationInteraction()
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

    private static func cameraReasonPriority(
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

    private static func isManualCameraReason(
        _ reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> Bool {
        switch reason {
        case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
            true
        default:
            false
        }
    }

    private func normalizeSelection() {
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
    private func mutateCaptionCues(
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

    private func sourceTime(atOutputTime outputTime: Double) -> Double {
        timeline.position(atOutputTime: outputTime)?.sourceTimeSeconds
            ?? min(max(outputTime.isFinite ? outputTime : 0, 0), sourceDurationSeconds)
    }

    private func makeVideoAnnotation(
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

    private func makeVideoFreehandAnnotation(
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

    private var nextVideoAnnotationStepNumber: Int {
        videoAnnotations
            .filter { $0.annotation.kind == .step }
            .compactMap { $0.annotation.text.flatMap(Int.init) }
            .max()
            .map { $0 + 1 }
            ?? 1
    }

    private var normalizedVideoAnnotationTextDraft: String {
        let value = videoAnnotationTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "文字" : value
    }

    private func appendVideoAnnotationDraftPoint(_ point: LensPoint) {
        guard let last = videoAnnotationDraftPath.last else {
            videoAnnotationDraftPath.append(point)
            return
        }
        guard hypot(point.x - last.x, point.y - last.y) >= 0.0008 else { return }
        videoAnnotationDraftPath.append(point)
    }

    private func simplifyVideoAnnotationPath(
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

    private func videoAnnotationPathLength(_ points: [LensPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }

    private func clamped(_ point: LensPoint) -> LensPoint {
        LensPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
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
