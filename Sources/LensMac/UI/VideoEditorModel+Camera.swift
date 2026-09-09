import AppKit
import Foundation
import LensCore

extension VideoEditorModel {
    func setCameraMotionEnabled(_ enabled: Bool) {
        mutate { $0.camera.mode = enabled ? "event-driven" : "off" }
    }

    func setAutomaticZoomScale(_ value: Double) {
        let requestedScale = min(max(value.isFinite ? value : 1.28, 1), 3)
        if let current = plan.camera.zoomScale, abs(current - requestedScale) < 0.0001 {
            return
        }
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

    func moveManualCameraFocus(fromOutputTime from: Double, toOutputTime to: Double) {
        let fromSource = sourceTime(atOutputTime: from)
        let toSource = sourceTime(atOutputTime: to)
        guard let index = plan.camera.keyframes.enumerated().min(by: {
            abs($0.element.time - fromSource) < abs($1.element.time - fromSource)
        })?.offset,
              plan.camera.keyframes[index].reason == .manualFocus else { return }
        mutate { plan in
            var keyframe = plan.camera.keyframes[index]
            keyframe = AutoEditPlan.CameraKeyframe(
                time: toSource,
                scale: keyframe.scale,
                center: keyframe.center,
                easing: keyframe.easing,
                reason: keyframe.reason
            )
            plan.camera.keyframes[index] = keyframe
            plan.camera.keyframes.sort { $0.time < $1.time }
        }
    }

    func removeManualCameraFocus(atOutputTime outputTime: Double) {
        let source = sourceTime(atOutputTime: outputTime)
        guard let index = plan.camera.keyframes.enumerated().min(by: {
            abs($0.element.time - source) < abs($1.element.time - source)
        })?.offset,
              plan.camera.keyframes[index].reason == .manualFocus else { return }
        mutate { plan in
            plan.camera.keyframes.remove(at: index)
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

    func movePresenterKeyframe(fromOutputTime from: Double, toOutputTime to: Double) {
        let fromSource = sourceTime(atOutputTime: from)
        let toSource = sourceTime(atOutputTime: to)
        guard let presenter = plan.presenterCamera,
              let index = nearestPresenterKeyframeIndex(
                  in: presenter,
                  sourceTime: fromSource
              ) else { return }
        mutate { plan in
            guard let current = plan.presenterCamera?.keyframes[index] else { return }
            plan.presenterCamera?.keyframes[index] = AutoEditPlan.PresenterCameraKeyframe(
                sourceTimeSeconds: toSource,
                center: current.center,
                size: current.size,
                easing: current.easing
            )
            plan.presenterCamera?.keyframes.sort {
                $0.sourceTimeSeconds < $1.sourceTimeSeconds
            }
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
        syncChangeState()
    }

    func endPresenterInteraction() {
        guard let start = presenterInteractionStartPlan else { return }
        presenterInteractionStartPlan = nil
        guard start != plan else { return }
        undoHistory.append(start)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        syncChangeState()
    }

    /// Begins a continuous inspector edit such as a slider drag. The plan can
    /// still change on every tick so the raw preview remains responsive; the
    /// undo stack is committed once when the gesture ends.
    func beginContinuousEdit() {
        guard continuousEditBaseline == nil else { return }
        continuousEditBaseline = plan
    }

    /// Commits the baseline captured by ``beginContinuousEdit`` as one undo
    /// entry. Calling this more than once is harmless and keeps keyboard
    /// accessibility interactions well-defined.
    func endContinuousEdit() {
        guard let baseline = continuousEditBaseline else { return }
        continuousEditBaseline = nil
        guard baseline != plan else { return }
        undoHistory.append(baseline)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        syncChangeState()
    }
}
