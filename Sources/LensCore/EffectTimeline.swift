import Foundation

public struct CameraFrameState: Equatable, Sendable {
    public let scale: Double
    public let center: LensPoint

    public init(scale: Double, center: LensPoint) {
        self.scale = scale
        self.center = center
    }
}

public enum EffectTimeline {
    public static func effectiveCameraKeyframes(
        for camera: AutoEditPlan.Camera
    ) -> [AutoEditPlan.CameraKeyframe] {
        guard camera.mode != "off" else { return [] }
        let intensityMultiplier = camera.zoomScale == nil
            ? min(max(camera.zoomIntensity, 0), 1) / 0.42
            : 1
        return camera.keyframes.map { keyframe in
            let isManual = switch keyframe.reason {
            case .manualAnchor, .manualFocus, .manualHold, .manualReturn:
                true
            default:
                false
            }
            return AutoEditPlan.CameraKeyframe(
                time: keyframe.time,
                scale: isManual
                    ? min(max(keyframe.scale, 1), 3)
                    : min(max(
                        1 + (keyframe.scale - 1) * intensityMultiplier,
                        1
                    ), 3),
                center: keyframe.center,
                easing: keyframe.easing,
                reason: keyframe.reason
            )
        }
    }

    public static func effectiveCameraState(
        at time: Double,
        camera: AutoEditPlan.Camera
    ) -> CameraFrameState {
        cameraState(at: time, keyframes: effectiveCameraKeyframes(for: camera))
    }

    public static func cameraState(
        at time: Double,
        keyframes: [AutoEditPlan.CameraKeyframe]
    ) -> CameraFrameState {
        let fallback = CameraFrameState(scale: 1, center: LensPoint(x: 0.5, y: 0.5))
        guard let first = keyframes.first else { return fallback }
        if time <= first.time {
            return CameraFrameState(scale: first.scale, center: first.center)
        }
        guard let nextIndex = firstIndex(atOrAfter: time, in: keyframes, time: \.time) else {
            guard let last = keyframes.last else { return fallback }
            return CameraFrameState(scale: last.scale, center: last.center)
        }
        let previous = keyframes[max(nextIndex - 1, 0)]
        let next = keyframes[nextIndex]
        let duration = max(next.time - previous.time, 0.000_001)
        let linearProgress = min(max((time - previous.time) / duration, 0), 1)
        let progress = eased(linearProgress, easing: next.easing)
        return CameraFrameState(
            scale: lerp(previous.scale, next.scale, progress),
            center: LensPoint(
                x: lerp(previous.center.x, next.center.x, progress),
                y: lerp(previous.center.y, next.center.y, progress)
            )
        )
    }

    public static func cursorPosition(
        at time: Double,
        keyframes: [AutoEditPlan.CursorKeyframe],
        smoothing: Double = 0.72,
        smoothingWindowMilliseconds: Double? = nil
    ) -> LensPoint? {
        guard let first = keyframes.first else { return nil }
        if time <= first.time { return first.position }
        guard let nextIndex = firstIndex(atOrAfter: time, in: keyframes, time: \.time) else {
            return keyframes.last?.position
        }
        let previous = keyframes[max(nextIndex - 1, 0)]
        let next = keyframes[nextIndex]
        let duration = max(next.time - previous.time, 0.000_001)
        let progress = min(max((time - previous.time) / duration, 0), 1)
        let linear = LensPoint(
            x: lerp(previous.position.x, next.position.x, progress),
            y: lerp(previous.position.y, next.position.y, progress)
        )
        let smoothingAmount: Double
        let maximumSegmentDuration: Double
        if let smoothingWindowMilliseconds {
            let window = min(max(
                smoothingWindowMilliseconds.isFinite
                    ? smoothingWindowMilliseconds
                    : 0,
                0
            ), 160)
            smoothingAmount = min(window / 80, 1)
            maximumSegmentDuration = max(window / 1_000 * 4, 1.0 / 240.0)
        } else {
            smoothingAmount = min(max(smoothing.isFinite ? smoothing : 0.72, 0), 1)
            maximumSegmentDuration = 0.30
        }
        guard smoothingAmount > 0.000_1,
              duration <= maximumSegmentDuration else { return linear }

        let before = keyframes[max(nextIndex - 2, 0)]
        let after = keyframes[min(nextIndex + 1, keyframes.count - 1)]
        let previousSpan = max(next.time - before.time, duration)
        let nextSpan = max(after.time - previous.time, duration)
        let tangent0 = LensPoint(
            x: (next.position.x - before.position.x) / previousSpan * duration,
            y: (next.position.y - before.position.y) / previousSpan * duration
        )
        let tangent1 = LensPoint(
            x: (after.position.x - previous.position.x) / nextSpan * duration,
            y: (after.position.y - previous.position.y) / nextSpan * duration
        )
        let progress2 = progress * progress
        let progress3 = progress2 * progress
        let h00 = 2 * progress3 - 3 * progress2 + 1
        let h10 = progress3 - 2 * progress2 + progress
        let h01 = -2 * progress3 + 3 * progress2
        let h11 = progress3 - progress2
        let cubic = LensPoint(
            x: h00 * previous.position.x
                + h10 * tangent0.x
                + h01 * next.position.x
                + h11 * tangent1.x,
            y: h00 * previous.position.y
                + h10 * tangent0.y
                + h01 * next.position.y
                + h11 * tangent1.y
        )
        return LensPoint(
            x: min(max(lerp(linear.x, cubic.x, smoothingAmount), 0), 1),
            y: min(max(lerp(linear.y, cubic.y, smoothingAmount), 0), 1)
        )
    }

    public static func lastCursorActivity(
        at time: Double,
        keyframes: [AutoEditPlan.CursorKeyframe]
    ) -> Double? {
        lastIndex(atOrBefore: time, in: keyframes, time: \.time).map {
            keyframes[$0].time
        }
    }

    public static func cursorKind(
        at time: Double,
        keyframes: [AutoEditPlan.CursorKeyframe]
    ) -> PointerEventKind? {
        guard let index = lastIndex(atOrBefore: time, in: keyframes, time: \.time) else {
            return keyframes.first?.kind
        }
        return keyframes[index].kind
    }

    /// Cursor tracks can contain hundreds of thousands of 60 Hz samples. A
    /// binary lookup keeps live preview and export sampling independent of the
    /// recording's total duration.
    private static func firstIndex<Element>(
        atOrAfter value: Double,
        in elements: [Element],
        time: (Element) -> Double
    ) -> Int? {
        guard !elements.isEmpty else { return nil }
        var lower = 0
        var upper = elements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if time(elements[middle]) < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < elements.count ? lower : nil
    }

    private static func lastIndex<Element>(
        atOrBefore value: Double,
        in elements: [Element],
        time: (Element) -> Double
    ) -> Int? {
        guard !elements.isEmpty else { return nil }
        var lower = 0
        var upper = elements.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if time(elements[middle]) <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower > 0 ? lower - 1 : nil
    }

    private static func eased(_ value: Double, easing: String) -> Double {
        switch easing {
        case "linear":
            return value
        case "spring-smooth":
            // Seek-safe smooth spring approximation without overshoot.
            return value * value * (3 - 2 * value)
        case "spring-gentle":
            let smooth = value * value * (3 - 2 * value)
            return 1 - pow(1 - smooth, 1.35)
        case "cinematic", "ease-in-out-smootherstep":
            return value * value * value * (value * (value * 6 - 15) + 10)
        case "ease-out-quint":
            return 1 - pow(1 - value, 5)
        case "critically-damped":
            guard value > 0 else { return 0 }
            guard value < 1 else { return 1 }
            let response = 5.0
            let raw = 1 - (1 + response * value) * exp(-response * value)
            let normalization = 1 - (1 + response) * exp(-response)
            return min(max(raw / max(normalization, 0.000_001), 0), 1)
        default:
            return value
        }
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }
}
