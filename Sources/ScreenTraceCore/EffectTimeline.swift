import Foundation

public struct CameraFrameState: Equatable, Sendable {
    public let scale: Double
    public let center: TracePoint

    public init(scale: Double, center: TracePoint) {
        self.scale = scale
        self.center = center
    }
}

public enum EffectTimeline {
    public static func cameraState(
        at time: Double,
        keyframes: [AutoEditPlan.CameraKeyframe]
    ) -> CameraFrameState {
        let fallback = CameraFrameState(scale: 1, center: TracePoint(x: 0.5, y: 0.5))
        guard let first = keyframes.first else { return fallback }
        if time <= first.time {
            return CameraFrameState(scale: first.scale, center: first.center)
        }
        guard let nextIndex = keyframes.firstIndex(where: { $0.time >= time }) else {
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
            center: TracePoint(
                x: lerp(previous.center.x, next.center.x, progress),
                y: lerp(previous.center.y, next.center.y, progress)
            )
        )
    }

    public static func cursorPosition(
        at time: Double,
        keyframes: [AutoEditPlan.CursorKeyframe]
    ) -> TracePoint? {
        guard let first = keyframes.first else { return nil }
        if time <= first.time { return first.position }
        guard let nextIndex = keyframes.firstIndex(where: { $0.time >= time }) else {
            return keyframes.last?.position
        }
        let previous = keyframes[max(nextIndex - 1, 0)]
        let next = keyframes[nextIndex]
        let duration = max(next.time - previous.time, 0.000_001)
        let progress = min(max((time - previous.time) / duration, 0), 1)
        return TracePoint(
            x: lerp(previous.position.x, next.position.x, progress),
            y: lerp(previous.position.y, next.position.y, progress)
        )
    }

    public static func lastCursorActivity(
        at time: Double,
        keyframes: [AutoEditPlan.CursorKeyframe]
    ) -> Double? {
        keyframes.last(where: { $0.time <= time })?.time
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
        default:
            return value
        }
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }
}
