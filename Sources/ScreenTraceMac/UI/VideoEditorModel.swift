import Foundation
import ScreenTraceCore

@MainActor
final class VideoEditorModel: ObservableObject {
    @Published private(set) var plan: AutoEditPlan
    @Published private(set) var selectedSegmentID: UUID?
    @Published private(set) var isDirty = false
    @Published private(set) var isProcessing = false

    let sourceDurationSeconds: Double
    let hasCameraTrack: Bool
    let hasMicrophoneTrack: Bool
    var onTimelineChanged: ((VideoEditTimeline) -> Void)?

    private let initialPlan: AutoEditPlan
    private var savedPlan: AutoEditPlan
    private var undoHistory: [AutoEditPlan] = []
    private var redoHistory: [AutoEditPlan] = []

    init(
        plan requestedPlan: AutoEditPlan,
        sourceDurationSeconds: Double,
        hasCameraTrack: Bool,
        hasMicrophoneTrack: Bool = false
    ) {
        let duration = max(sourceDurationSeconds.isFinite ? sourceDurationSeconds : 0, 0)
        var plan = requestedPlan
        plan.schemaVersion = AutoEditPlan.currentSchemaVersion
        plan.timeline = (plan.timeline ?? VideoEditTimeline(
            sourceDurationSeconds: duration
        )).normalized(sourceDurationSeconds: duration)
        self.plan = plan
        initialPlan = plan
        savedPlan = plan
        self.sourceDurationSeconds = duration
        self.hasCameraTrack = hasCameraTrack
        self.hasMicrophoneTrack = hasMicrophoneTrack
        selectedSegmentID = plan.timeline?.activeSegments.first?.id
    }

    var timeline: VideoEditTimeline {
        plan.timeline ?? VideoEditTimeline(sourceDurationSeconds: sourceDurationSeconds)
    }

    var activeSegments: [VideoEditSegment] { timeline.activeSegments }
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
    var cameraMotionEnabled: Bool { plan.camera.mode != "off" }
    var cursorEnabled: Bool { plan.cursor.isEnabled != false }
    var clickPulseEnabled: Bool { plan.interaction?.showsClickPulse != false }
    var canvasEnabled: Bool { plan.canvas?.isEnabled != false }
    var presenterEnabled: Bool { plan.presenterCamera?.isEnabled == true }
    var audioEnabled: Bool { plan.audio?.isEnabled != false }

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

    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(plan)
        plan = previous
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(plan)
        plan = next
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func resetToAutomaticPlan() {
        guard plan != initialPlan else { return }
        undoHistory.append(plan)
        redoHistory.removeAll()
        plan = initialPlan
        normalizeSelection()
        isDirty = plan != savedPlan
        onTimelineChanged?(timeline)
    }

    func markSaved() {
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
}
