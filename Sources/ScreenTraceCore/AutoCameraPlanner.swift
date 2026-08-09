import Foundation

public struct AutoCameraPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var focusScale: Double
        public var zoomDuration: Double
        public var followWindow: Double
        public var holdDuration: Double
        public var returnDuration: Double

        public init(
            focusScale: Double = 1.58,
            zoomDuration: Double = 0.20,
            followWindow: Double = 1.00,
            holdDuration: Double = 0.72,
            returnDuration: Double = 0.34
        ) {
            self.focusScale = max(focusScale, 1)
            self.zoomDuration = max(zoomDuration, 0)
            self.followWindow = max(followWindow, 0)
            self.holdDuration = max(holdDuration, 0)
            self.returnDuration = max(returnDuration, 0)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func plan(
        clicks: [ClickEvent],
        duration: Double
    ) -> [AutoEditPlan.CameraKeyframe] {
        let duration = max(duration, 0)
        let overview = TracePoint(x: 0.5, y: 0.5)
        var keyframes = [AutoEditPlan.CameraKeyframe(
            time: 0,
            scale: 1,
            center: overview,
            easing: "linear",
            reason: .baseline
        )]

        let focusClicks = clicks
            .filter { $0.phase == .down && $0.normalizedLocation != nil && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        guard !focusClicks.isEmpty else { return keyframes }

        var previousClick: ClickEvent?
        for click in focusClicks {
            if let previousClick,
               click.time - previousClick.time > configuration.followWindow {
                appendExit(
                    after: previousClick,
                    before: click.time,
                    duration: duration,
                    overview: overview,
                    to: &keyframes
                )
            }

            guard let requestedCenter = click.normalizedLocation else { continue }
            let focusTime = min(click.time + configuration.zoomDuration, duration)
            appendIfLater(AutoEditPlan.CameraKeyframe(
                time: focusTime,
                scale: configuration.focusScale,
                center: clampedCenter(requestedCenter, scale: configuration.focusScale),
                easing: "spring-smooth",
                reason: .clickFocus
            ), to: &keyframes)
            previousClick = click
        }

        if let previousClick {
            appendExit(
                after: previousClick,
                before: nil,
                duration: duration,
                overview: overview,
                to: &keyframes
            )
        }
        return deduplicated(keyframes)
    }

    private func appendExit(
        after click: ClickEvent,
        before nextClickTime: Double?,
        duration: Double,
        overview: TracePoint,
        to keyframes: inout [AutoEditPlan.CameraKeyframe]
    ) {
        let latestCenter = keyframes.last?.center ?? overview
        var holdTime = click.time + configuration.zoomDuration + configuration.holdDuration
        var returnTime = holdTime + configuration.returnDuration

        if let nextClickTime {
            returnTime = min(returnTime, max(click.time + configuration.zoomDuration, nextClickTime - 0.08))
            holdTime = min(holdTime, max(click.time + configuration.zoomDuration, returnTime - configuration.returnDuration))
        }
        holdTime = min(holdTime, duration)
        returnTime = min(returnTime, duration)

        appendIfLater(AutoEditPlan.CameraKeyframe(
            time: holdTime,
            scale: configuration.focusScale,
            center: latestCenter,
            easing: "linear",
            reason: .clickHold
        ), to: &keyframes)
        appendIfLater(AutoEditPlan.CameraKeyframe(
            time: returnTime,
            scale: 1,
            center: overview,
            easing: "spring-gentle",
            reason: .returnToOverview
        ), to: &keyframes)
    }

    private func clampedCenter(_ point: TracePoint, scale: Double) -> TracePoint {
        let safeScale = max(scale, 1)
        let halfVisible = 0.5 / safeScale
        return TracePoint(
            x: min(max(point.x, halfVisible), 1 - halfVisible),
            y: min(max(point.y, halfVisible), 1 - halfVisible)
        )
    }

    private func appendIfLater(
        _ keyframe: AutoEditPlan.CameraKeyframe,
        to keyframes: inout [AutoEditPlan.CameraKeyframe]
    ) {
        guard keyframe.time >= (keyframes.last?.time ?? 0) else { return }
        keyframes.append(keyframe)
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
}
