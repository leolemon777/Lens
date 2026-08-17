import Foundation

public struct CursorPathPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var slowTimeConstant: Double
        public var fastTimeConstant: Double
        public var speedForFastResponse: Double

        public init(
            slowTimeConstant: Double = 0.085,
            fastTimeConstant: Double = 0.018,
            speedForFastResponse: Double = 1.25
        ) {
            self.slowTimeConstant = max(slowTimeConstant, 0.001)
            self.fastTimeConstant = max(fastTimeConstant, 0.001)
            self.speedForFastResponse = max(speedForFastResponse, 0.001)
        }

        public init(smoothing: Double) {
            let smoothing = min(max(smoothing.isFinite ? smoothing : 0.72, 0), 1)
            slowTimeConstant = 0.035 + smoothing * 0.075
            fastTimeConstant = 0.010 + smoothing * 0.016
            speedForFastResponse = 0.95 + smoothing * 0.45
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func rawPlan(events: [PointerEvent]) -> [AutoEditPlan.CursorKeyframe] {
        events
            .filter {
                $0.kind != .scroll
                    && $0.normalizedLocation != nil
                    && $0.time >= 0
            }
            .sorted { $0.time < $1.time }
            .compactMap { event in
                guard let position = event.normalizedLocation else { return nil }
                return AutoEditPlan.CursorKeyframe(
                    time: event.time,
                    position: clamped(position),
                    kind: event.kind
                )
            }
    }

    /// Keeps only actual cursor-shape changes so the edit plan stays compact
    /// even when pointer locations are sampled at 60 Hz.
    public func shapePlan(
        events: [PointerEvent],
        clicks: [ClickEvent] = []
    ) -> [AutoEditPlan.CursorShapeKeyframe] {
        let pointerCandidates = events.compactMap { event -> AutoEditPlan.CursorShapeKeyframe? in
            guard event.time >= 0,
                  event.kind != .scroll,
                  let shape = event.cursorShape else { return nil }
            return AutoEditPlan.CursorShapeKeyframe(time: event.time, shape: shape)
        }
        let clickCandidates = clicks.compactMap { event -> AutoEditPlan.CursorShapeKeyframe? in
            guard event.time >= 0, let shape = event.cursorShape else { return nil }
            return AutoEditPlan.CursorShapeKeyframe(time: event.time, shape: shape)
        }
        let candidates = (pointerCandidates + clickCandidates).sorted { $0.time < $1.time }
        var lastShape: PointerCursorShape?
        var result: [AutoEditPlan.CursorShapeKeyframe] = []
        for candidate in candidates {
            guard candidate.shape != lastShape else { continue }
            result.append(candidate)
            lastShape = candidate.shape
        }
        return result
    }

    public func plan(events: [PointerEvent]) -> [AutoEditPlan.CursorKeyframe] {
        let events = events
            .filter {
                $0.kind != .scroll
                    && $0.normalizedLocation != nil
                    && $0.time >= 0
            }
            .sorted { $0.time < $1.time }
        guard let firstEvent = events.first,
              let firstPosition = firstEvent.normalizedLocation else {
            return []
        }

        var result = [AutoEditPlan.CursorKeyframe(
            time: firstEvent.time,
            position: clamped(firstPosition),
            kind: firstEvent.kind
        )]
        var previousRaw = clamped(firstPosition)
        var previousSmoothed = previousRaw
        var previousTime = firstEvent.time

        for event in events.dropFirst() {
            guard let rawLocation = event.normalizedLocation else { continue }
            let raw = clamped(rawLocation)
            let deltaTime = max(event.time - previousTime, 1.0 / 240.0)
            let distance = hypot(raw.x - previousRaw.x, raw.y - previousRaw.y)
            let speed = distance / deltaTime
            let response = min(max(speed / configuration.speedForFastResponse, 0), 1)
            let timeConstant = configuration.slowTimeConstant
                + (configuration.fastTimeConstant - configuration.slowTimeConstant) * response
            let alpha = 1 - exp(-deltaTime / timeConstant)
            let smoothed = TracePoint(
                x: previousSmoothed.x + (raw.x - previousSmoothed.x) * alpha,
                y: previousSmoothed.y + (raw.y - previousSmoothed.y) * alpha
            )

            result.append(AutoEditPlan.CursorKeyframe(
                time: event.time,
                position: clamped(smoothed),
                kind: event.kind
            ))
            previousRaw = raw
            previousSmoothed = smoothed
            previousTime = event.time
        }
        return result
    }

    private func clamped(_ point: TracePoint) -> TracePoint {
        TracePoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }
}
