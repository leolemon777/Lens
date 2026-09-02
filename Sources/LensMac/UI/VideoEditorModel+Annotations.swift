import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
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

    /// Returns true when Escape should stay in the editor instead of closing it.
    @discardableResult
    func escapeCurrentMode() -> Bool {
        if isManualCameraFocusEditing {
            cancelManualCameraFocusEditing()
            return true
        }
        if videoAnnotationDraft != nil || videoAnnotationInteractionActive {
            cancelVideoAnnotationDraft()
            cancelVideoAnnotationInteraction()
            return true
        }
        if isVideoAnnotationEditing {
            finishVideoAnnotationEditing()
            return true
        }
        return false
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
        syncChangeState()
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
        syncChangeState()
    }

    func cancelVideoAnnotationInteraction() {
        videoAnnotationInteractionActive = false
        guard let activeVideoAnnotationTransform else { return }
        plan = activeVideoAnnotationTransform.baseline
        self.activeVideoAnnotationTransform = nil
        syncChangeState()
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
}
