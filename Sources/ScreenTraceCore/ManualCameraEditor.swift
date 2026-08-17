import Foundation

public struct ManualCameraEditor: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var transitionDuration: Double
        public var holdDuration: Double
        public var returnDuration: Double

        public init(
            transitionDuration: Double = 0.24,
            holdDuration: Double = 1.20,
            returnDuration: Double = 0.36
        ) {
            self.transitionDuration = max(
                transitionDuration.isFinite ? transitionDuration : 0.24,
                0
            )
            self.holdDuration = max(
                holdDuration.isFinite ? holdDuration : 1.20,
                0
            )
            self.returnDuration = max(
                returnDuration.isFinite ? returnDuration : 0.36,
                0
            )
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func insertingFocus(
        at sourceTime: Double,
        center: TracePoint,
        scale: Double,
        duration: Double,
        into camera: AutoEditPlan.Camera
    ) -> AutoEditPlan.Camera {
        let duration = max(duration.isFinite ? duration : 0, 0)
        let focusTime = min(max(sourceTime.isFinite ? sourceTime : 0, 0), duration)
        let focusScale = min(max(scale.isFinite ? scale : 1.8, 1), 3)
        let focusCenter = clampedCenter(center, scale: focusScale)
        let anchorTime = max(focusTime - configuration.transitionDuration, 0)
        let holdTime = min(focusTime + configuration.holdDuration, duration)
        let returnTime = min(holdTime + configuration.returnDuration, duration)
        let anchorState = EffectTimeline.effectiveCameraState(
            at: anchorTime,
            camera: camera
        )

        var updated = camera
        updated.mode = "event-driven"
        updated.keyframes.removeAll {
            $0.time >= anchorTime - 0.000_001
                && $0.time <= returnTime + 0.000_001
        }
        if anchorTime < focusTime - 0.000_001 {
            updated.keyframes.append(AutoEditPlan.CameraKeyframe(
                time: anchorTime,
                scale: anchorState.scale,
                center: anchorState.center,
                easing: "linear",
                reason: .manualAnchor
            ))
        }
        updated.keyframes.append(AutoEditPlan.CameraKeyframe(
            time: focusTime,
            scale: focusScale,
            center: focusCenter,
            easing: "cinematic",
            reason: .manualFocus
        ))
        if holdTime > focusTime + 0.000_001 {
            updated.keyframes.append(AutoEditPlan.CameraKeyframe(
                time: holdTime,
                scale: focusScale,
                center: focusCenter,
                easing: "linear",
                reason: .manualHold
            ))
        }
        if returnTime > holdTime + 0.000_001 {
            updated.keyframes.append(AutoEditPlan.CameraKeyframe(
                time: returnTime,
                scale: 1,
                center: TracePoint(x: 0.5, y: 0.5),
                easing: "spring-gentle",
                reason: .manualReturn
            ))
        }
        updated.keyframes.sort { lhs, rhs in
            if abs(lhs.time - rhs.time) > 0.000_001 {
                return lhs.time < rhs.time
            }
            return Self.priority(lhs.reason) < Self.priority(rhs.reason)
        }
        updated.keyframes = deduplicated(updated.keyframes)
        return updated
    }

    public func removingManualKeyframes(
        from camera: AutoEditPlan.Camera
    ) -> AutoEditPlan.Camera {
        var updated = camera
        updated.keyframes.removeAll { Self.isManual($0.reason) }
        return updated
    }

    public static func isManual(
        _ reason: AutoEditPlan.CameraKeyframe.Reason
    ) -> Bool {
        switch reason {
        case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
            true
        default:
            false
        }
    }

    private func clampedCenter(_ point: TracePoint, scale: Double) -> TracePoint {
        let halfVisible = 0.5 / max(scale, 1)
        return TracePoint(
            x: min(max(point.x.isFinite ? point.x : 0.5, halfVisible), 1 - halfVisible),
            y: min(max(point.y.isFinite ? point.y : 0.5, halfVisible), 1 - halfVisible)
        )
    }

    private func deduplicated(
        _ keyframes: [AutoEditPlan.CameraKeyframe]
    ) -> [AutoEditPlan.CameraKeyframe] {
        var result: [AutoEditPlan.CameraKeyframe] = []
        for keyframe in keyframes {
            if let last = result.last, abs(last.time - keyframe.time) < 0.000_001 {
                result[result.count - 1] = keyframe
            } else {
                result.append(keyframe)
            }
        }
        return result
    }

    private static func priority(
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
}
