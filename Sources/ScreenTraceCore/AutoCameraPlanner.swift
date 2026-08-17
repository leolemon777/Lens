import Foundation

public struct AutoCameraPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var focusScale: Double
        public var focusLeadIn: Double
        public var zoomDuration: Double
        public var followWindow: Double
        public var followSamplingInterval: Double
        public var pointerSafeArea: Double
        public var pointerHysteresis: Double
        public var pointerLookAhead: Double
        public var maximumPanSpeed: Double
        public var maximumPanAcceleration: Double
        public var maximumZoomVelocity: Double
        public var maximumTransitionDuration: Double
        public var nearbyClickRadius: Double
        public var clickClusterInterval: Double
        public var clickFocusSafeArea: Double
        public var holdDuration: Double
        public var returnDuration: Double
        public var minimumOverviewDwell: Double
        public var pointerFocusScale: Double
        public var pointerActivityGap: Double
        public var pointerMinimumTravel: Double
        public var pointerActivityHoldDuration: Double
        public var scrollActivityGap: Double
        public var scrollSettleDelay: Double

        public init(
            focusScale: Double = 1.60,
            focusLeadIn: Double = 0.30,
            zoomDuration: Double = 0.62,
            followWindow: Double = 3.40,
            followSamplingInterval: Double = 0.18,
            pointerSafeArea: Double = 0.52,
            pointerHysteresis: Double = 0.16,
            pointerLookAhead: Double = 0.10,
            maximumPanSpeed: Double = 0.30,
            maximumPanAcceleration: Double = 0.80,
            maximumZoomVelocity: Double = 1.60,
            maximumTransitionDuration: Double = 1.55,
            nearbyClickRadius: Double = 0.075,
            clickClusterInterval: Double = 0.95,
            clickFocusSafeArea: Double = 0.58,
            holdDuration: Double = 2.00,
            returnDuration: Double = 0.95,
            minimumOverviewDwell: Double = 0.60,
            pointerFocusScale: Double = 1.32,
            pointerActivityGap: Double = 0.90,
            pointerMinimumTravel: Double = 0.055,
            pointerActivityHoldDuration: Double = 1.10,
            scrollActivityGap: Double = 0.20,
            scrollSettleDelay: Double = 0.45
        ) {
            self.focusScale = max(focusScale, 1)
            self.focusLeadIn = max(focusLeadIn, 0)
            self.zoomDuration = max(zoomDuration, 0)
            self.followWindow = max(followWindow, 0)
            self.followSamplingInterval = max(followSamplingInterval, 0.04)
            self.pointerSafeArea = min(max(pointerSafeArea, 0.10), 0.95)
            self.pointerHysteresis = min(max(pointerHysteresis, 0), 0.40)
            self.pointerLookAhead = min(max(pointerLookAhead, 0), 0.35)
            self.maximumPanSpeed = max(maximumPanSpeed, 0.05)
            self.maximumPanAcceleration = max(maximumPanAcceleration, 0.10)
            self.maximumZoomVelocity = max(maximumZoomVelocity, 0.10)
            self.maximumTransitionDuration = max(
                maximumTransitionDuration,
                self.zoomDuration
            )
            self.nearbyClickRadius = max(nearbyClickRadius, 0)
            self.clickClusterInterval = max(clickClusterInterval, 0.10)
            self.clickFocusSafeArea = min(max(clickFocusSafeArea, 0.10), 0.95)
            self.holdDuration = max(holdDuration, 0)
            self.returnDuration = max(returnDuration, 0)
            self.minimumOverviewDwell = max(minimumOverviewDwell, 0)
            self.pointerFocusScale = max(pointerFocusScale, 1)
            self.pointerActivityGap = max(pointerActivityGap, 0.20)
            self.pointerMinimumTravel = max(pointerMinimumTravel, 0.01)
            self.pointerActivityHoldDuration = max(pointerActivityHoldDuration, 0)
            self.scrollActivityGap = max(scrollActivityGap, 0.05)
            self.scrollSettleDelay = max(scrollSettleDelay, 0)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public init(camera: AutoEditPlan.Camera) {
        let focusScale = camera.resolvedZoomScale
        let pointerScale = min(max(1 + (focusScale - 1) * 0.65, 1.18), focusScale)
        configuration = switch camera.generationStrength {
        case .restrained:
            Configuration(
                focusScale: focusScale,
                focusLeadIn: 0.34,
                zoomDuration: 0.82,
                followWindow: 4.20,
                followSamplingInterval: 0.24,
                pointerSafeArea: 0.62,
                pointerHysteresis: 0.20,
                maximumPanSpeed: 0.22,
                maximumPanAcceleration: 0.50,
                maximumZoomVelocity: 1.25,
                maximumTransitionDuration: 1.85,
                clickClusterInterval: 1.10,
                clickFocusSafeArea: 0.66,
                holdDuration: 2.50,
                returnDuration: 1.15,
                minimumOverviewDwell: 0.90,
                pointerFocusScale: pointerScale,
                pointerActivityGap: 1.10,
                pointerMinimumTravel: 0.080,
                pointerActivityHoldDuration: 1.50,
                scrollActivityGap: 0.22,
                scrollSettleDelay: 0.65
            )
        case .balanced:
            Configuration(
                focusScale: focusScale,
                focusLeadIn: 0.30,
                zoomDuration: 0.68,
                followWindow: 3.60,
                followSamplingInterval: 0.18,
                pointerSafeArea: 0.54,
                pointerHysteresis: 0.16,
                maximumPanSpeed: 0.30,
                maximumPanAcceleration: 0.80,
                maximumZoomVelocity: 1.60,
                maximumTransitionDuration: 1.55,
                clickClusterInterval: 0.95,
                clickFocusSafeArea: 0.60,
                holdDuration: 2.00,
                returnDuration: 0.95,
                minimumOverviewDwell: 0.60,
                pointerFocusScale: pointerScale
            )
        case .active:
            Configuration(
                focusScale: focusScale,
                focusLeadIn: 0.32,
                zoomDuration: 0.48,
                followWindow: 1.80,
                followSamplingInterval: 0.12,
                pointerSafeArea: 0.38,
                pointerHysteresis: 0.08,
                maximumPanSpeed: 0.42,
                maximumPanAcceleration: 1.30,
                maximumZoomVelocity: 2.40,
                maximumTransitionDuration: 1.20,
                clickClusterInterval: 0.70,
                clickFocusSafeArea: 0.42,
                holdDuration: 1.55,
                returnDuration: 0.76,
                minimumOverviewDwell: 0.08,
                pointerFocusScale: pointerScale,
                pointerActivityGap: 0.65,
                pointerMinimumTravel: 0.035,
                pointerActivityHoldDuration: 0.80,
                scrollActivityGap: 0.14,
                scrollSettleDelay: 0.30
            )
        }
    }

    public func plan(
        clicks: [ClickEvent],
        pointerEvents: [PointerEvent] = [],
        followPointer: Bool = true,
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
        let scrollLocks = scrollLockRanges(
            pointerEvents: pointerEvents,
            duration: duration
        )
        let cameraPointerEvents = pointerEvents.filter {
            $0.kind != .scroll && !isLocked($0.time, by: scrollLocks)
        }

        let focusClicks = clicks
            .filter { $0.phase == .down && $0.normalizedLocation != nil && $0.time >= 0 && $0.time <= duration }
            .map { click -> (event: ClickEvent, wasDeferredByScroll: Bool) in
                let decisionTime = scrollLocks.first(where: { $0.contains(click.time) })?
                    .upperBound ?? click.time
                let event = ClickEvent(
                    time: min(decisionTime, duration),
                    button: click.button,
                    phase: click.phase,
                    location: click.location,
                    normalizedLocation: click.normalizedLocation,
                    displayID: click.displayID,
                    clickCount: click.clickCount
                )
                return (event, decisionTime > click.time + 0.000_001)
            }
            .sorted { $0.event.time < $1.event.time }
        guard !focusClicks.isEmpty else {
            guard followPointer else { return keyframes }
            let pointerBase = pointerActivityBase(
                pointerEvents: cameraPointerEvents,
                duration: duration,
                overview: overview
            )
            return insertingPointerFollow(
                into: pointerBase,
                pointerEvents: cameraPointerEvents,
                duration: duration
            )
        }

        var previousClick: ClickEvent?
        var hasActiveFocus = false
        var activeFocusCenter: TracePoint?
        for (focusIndex, focusClick) in focusClicks.enumerated() {
            let click = focusClick.event
            let isFinalClick = focusIndex == focusClicks.count - 1
            if hasActiveFocus,
               let previousClick,
               shouldReturnToOverview(after: previousClick, before: click.time) {
                appendExit(
                    after: previousClick,
                    before: click.time,
                    duration: duration,
                    overview: overview,
                    to: &keyframes
                )
                hasActiveFocus = false
                activeFocusCenter = nil
            }

            guard let requestedCenter = click.normalizedLocation else { continue }
            let isNearbyRepeat: Bool = {
                guard let previousClick,
                      let previousLocation = previousClick.normalizedLocation,
                      click.time - previousClick.time <= configuration.clickClusterInterval else {
                    return false
                }
                return hypot(
                    requestedCenter.x - previousLocation.x,
                    requestedCenter.y - previousLocation.y
                ) <= configuration.nearbyClickRadius
            }()
            let isInsideCurrentFocus = activeFocusCenter.map {
                isInsideClickFocusSafeArea(requestedCenter, focusCenter: $0)
            } ?? false
            if !isNearbyRepeat, !isInsideCurrentFocus {
                // A camera move must communicate the user's action, not predict
                // it. Keep the composition still through mouse-down, show the
                // click at its true location, then carry that target region to
                // the visual center. This also removes the disorienting feeling
                // that the world is chasing an invisible pointer.
                let anchorTime = min(max(click.time, 0), duration)
                let anchorState = EffectTimeline.cameraState(
                    at: anchorTime,
                    keyframes: keyframes
                )
                appendIfLater(AutoEditPlan.CameraKeyframe(
                    time: anchorTime,
                    scale: anchorState.scale,
                    center: anchorState.center,
                    easing: "linear",
                    reason: hasActiveFocus ? .clickHold : .baseline
                ), to: &keyframes)
                let effectiveAnchorTime = keyframes.last?.time ?? anchorTime
                let focusCenter = clampedCenter(
                    requestedCenter,
                    scale: configuration.focusScale
                )
                let requestedTransitionDuration = transitionDuration(
                    from: anchorState,
                    toScale: configuration.focusScale,
                    center: focusCenter
                )
                // The final automatic shot must leave enough tail to return to
                // the overview. Starting a zoom that cannot complete its exit
                // leaves the recording visibly stuck on a cropped page. For
                // non-final shots, keeping the current composition is calmer
                // than compressing a full zoom into the remaining frames.
                let requiredTail = requestedTransitionDuration
                    + (isFinalClick ? configuration.returnDuration : 0)
                guard duration - effectiveAnchorTime >= requiredTail else {
                    previousClick = click
                    hasActiveFocus = anchorState.scale > 1.01
                    activeFocusCenter = hasActiveFocus ? anchorState.center : nil
                    continue
                }
                let focusTime = effectiveAnchorTime + requestedTransitionDuration
                appendIfLater(AutoEditPlan.CameraKeyframe(
                    time: focusTime,
                    scale: configuration.focusScale,
                    center: focusCenter,
                    easing: "ease-in-out-smootherstep",
                    reason: .clickFocus
                ), to: &keyframes)
                activeFocusCenter = focusCenter
            }
            previousClick = click
            hasActiveFocus = true
        }

        if hasActiveFocus, let previousClick {
            appendExit(
                after: previousClick,
                before: nil,
                duration: duration,
                overview: overview,
                to: &keyframes
            )
        }
        // Once clicks exist they are the semantic targets. Ordinary movement
        // between them must never retarget the shot; `followPointer` remains a
        // useful fallback only for demonstrations that contain no clicks.
        return deduplicated(keyframes)
    }

    /// Creates a restrained camera beat for recordings that contain meaningful
    /// pointer movement but no clicks. Previously those recordings always stayed
    /// at 1×, which made the "follow pointer" option appear broken.
    private func pointerActivityBase(
        pointerEvents: [PointerEvent],
        duration: Double,
        overview: TracePoint
    ) -> [AutoEditPlan.CameraKeyframe] {
        let pointer = CursorPathPlanner(configuration: .init(smoothing: 0.84))
            .plan(events: pointerEvents)
            .filter { $0.time >= 0 && $0.time <= duration }
        guard pointer.count >= 2 else {
            return [AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: overview,
                easing: "linear",
                reason: .baseline
            )]
        }

        struct Activity {
            var start: Double
            var end: Double
            var startPosition: TracePoint
            var endPosition: TracePoint
            var travel: Double
        }
        var activities: [Activity] = []
        var activity: Activity?
        for (previous, current) in zip(pointer, pointer.dropFirst()) {
            guard current.time - previous.time <= configuration.pointerActivityGap else {
                if let activity,
                   activity.travel >= configuration.pointerMinimumTravel {
                    activities.append(activity)
                }
                activity = nil
                continue
            }
            let distance = hypot(
                current.position.x - previous.position.x,
                current.position.y - previous.position.y
            )
            // A slow, deliberate approach to a target is made of steps too small
            // to clear a per-step threshold, yet it is exactly the moment worth
            // framing. Let small steps accumulate and rely on the cumulative
            // `pointerMinimumTravel` check to discard genuine jitter.
            if var active = activity,
               previous.time - active.end <= configuration.pointerActivityGap {
                active.end = current.time
                active.endPosition = current.position
                active.travel += distance
                activity = active
            } else {
                if let activity,
                   activity.travel >= configuration.pointerMinimumTravel {
                    activities.append(activity)
                }
                activity = Activity(
                    start: previous.time,
                    end: current.time,
                    startPosition: previous.position,
                    endPosition: current.position,
                    travel: distance
                )
            }
        }
        if let activity,
           activity.travel >= configuration.pointerMinimumTravel {
            activities.append(activity)
        }
        guard !activities.isEmpty else {
            return [AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: overview,
                easing: "linear",
                reason: .baseline
            )]
        }

        var result = [AutoEditPlan.CameraKeyframe(
            time: 0,
            scale: 1,
            center: overview,
            easing: "linear",
            reason: .baseline
        )]
        for activity in activities {
            let anchorTime = min(max(activity.start - configuration.focusLeadIn, 0), duration)
            let focusTime = min(anchorTime + configuration.zoomDuration, duration)
            let holdTime = min(
                activity.end + configuration.pointerActivityHoldDuration,
                duration
            )
            let returnTime = min(holdTime + configuration.returnDuration, duration)
            guard focusTime > (result.last?.time ?? -1) else { continue }
            appendIfLater(AutoEditPlan.CameraKeyframe(
                time: anchorTime,
                scale: 1,
                center: overview,
                easing: "linear",
                reason: .baseline
            ), to: &result)
            appendIfLater(AutoEditPlan.CameraKeyframe(
                time: focusTime,
                scale: configuration.pointerFocusScale,
                center: clampedCenter(
                    activity.startPosition,
                    scale: configuration.pointerFocusScale
                ),
                easing: "ease-in-out-smootherstep",
                reason: .pointerFollow
            ), to: &result)
            appendIfLater(AutoEditPlan.CameraKeyframe(
                time: holdTime,
                scale: configuration.pointerFocusScale,
                center: clampedCenter(
                    activity.endPosition,
                    scale: configuration.pointerFocusScale
                ),
                easing: "linear",
                reason: .pointerFollow
            ), to: &result)
            appendIfLater(AutoEditPlan.CameraKeyframe(
                time: returnTime,
                scale: 1,
                center: overview,
                easing: "critically-damped",
                reason: .returnToOverview
            ), to: &result)
        }
        return deduplicated(result)
    }

    private func insertingPointerFollow(
        into base: [AutoEditPlan.CameraKeyframe],
        pointerEvents: [PointerEvent],
        duration: Double
    ) -> [AutoEditPlan.CameraKeyframe] {
        let smoothedPointer = CursorPathPlanner(configuration: .init(
            smoothing: 0.84
        )).plan(events: pointerEvents)
        guard !smoothedPointer.isEmpty else { return base }

        var inserted: [AutoEditPlan.CameraKeyframe] = []
        var lastSampleTime = -Double.infinity
        var lastCenter: TracePoint?
        var lastVelocity = TracePoint(x: 0, y: 0)
        for pointer in smoothedPointer where pointer.time >= 0 && pointer.time <= duration {
            guard pointer.time - lastSampleTime >= configuration.followSamplingInterval else {
                continue
            }
            let state = EffectTimeline.cameraState(at: pointer.time, keyframes: base)
            guard state.scale >= 1.18 else {
                lastCenter = nil
                lastVelocity = TracePoint(x: 0, y: 0)
                lastSampleTime = pointer.time
                continue
            }
            let predicted = EffectTimeline.cursorPosition(
                at: min(pointer.time + configuration.pointerLookAhead, duration),
                keyframes: smoothedPointer,
                smoothing: 0.84
            ) ?? pointer.position
            let currentCenter = lastCenter ?? state.center
            let visibleHalf = 0.5 / state.scale
            let isActivelyPanning = hypot(lastVelocity.x, lastVelocity.y) >= 0.01
            let hysteresisMultiplier = isActivelyPanning
                ? 1 - configuration.pointerHysteresis
                : 1 + configuration.pointerHysteresis
            let safeHalf = visibleHalf
                * configuration.pointerSafeArea
                * hysteresisMultiplier
            var requestedX = currentCenter.x
            var requestedY = currentCenter.y
            if predicted.x < currentCenter.x - safeHalf {
                requestedX = predicted.x + safeHalf
            } else if predicted.x > currentCenter.x + safeHalf {
                requestedX = predicted.x - safeHalf
            }
            if predicted.y < currentCenter.y - safeHalf {
                requestedY = predicted.y + safeHalf
            } else if predicted.y > currentCenter.y + safeHalf {
                requestedY = predicted.y - safeHalf
            }
            let requestedCenter = clampedCenter(
                TracePoint(x: requestedX, y: requestedY),
                scale: state.scale
            )
            let elapsed = lastSampleTime.isFinite
                ? max(pointer.time - lastSampleTime, configuration.followSamplingInterval)
                : configuration.followSamplingInterval
            let deltaX = requestedCenter.x - currentCenter.x
            let deltaY = requestedCenter.y - currentCenter.y
            let distance = hypot(deltaX, deltaY)
            let requestedSpeed = min(
                distance / max(elapsed, 0.000_001),
                configuration.maximumPanSpeed
            )
            let desiredVelocity = TracePoint(
                x: distance > 0 ? deltaX / distance * requestedSpeed : 0,
                y: distance > 0 ? deltaY / distance * requestedSpeed : 0
            )
            let velocityDeltaX = desiredVelocity.x - lastVelocity.x
            let velocityDeltaY = desiredVelocity.y - lastVelocity.y
            let velocityDelta = hypot(velocityDeltaX, velocityDeltaY)
            let maximumVelocityDelta = configuration.maximumPanAcceleration * elapsed
            let accelerationStep = velocityDelta > maximumVelocityDelta
                ? maximumVelocityDelta / max(velocityDelta, 0.000_001)
                : 1
            let velocity = TracePoint(
                x: lastVelocity.x + velocityDeltaX * accelerationStep,
                y: lastVelocity.y + velocityDeltaY * accelerationStep
            )
            let center = clampedCenter(TracePoint(
                x: currentCenter.x + velocity.x * elapsed,
                y: currentCenter.y + velocity.y * elapsed
            ), scale: state.scale)
            if hypot(center.x - currentCenter.x, center.y - currentCenter.y) < 0.008 {
                lastSampleTime = pointer.time
                lastCenter = currentCenter
                lastVelocity = TracePoint(
                    x: lastVelocity.x * 0.45,
                    y: lastVelocity.y * 0.45
                )
                continue
            }
            // Preserve the authored click focus and return beats. Pointer follow
            // fills the stable zoom interval instead of fighting those transitions.
            guard !base.contains(where: { abs($0.time - pointer.time) < 0.075 }) else {
                continue
            }
            inserted.append(AutoEditPlan.CameraKeyframe(
                time: pointer.time,
                scale: state.scale,
                center: center,
                easing: "ease-in-out-smootherstep",
                reason: .pointerFollow
            ))
            lastSampleTime = pointer.time
            lastCenter = center
            lastVelocity = velocity
        }
        guard !inserted.isEmpty else { return base }

        var combined = base + inserted
        combined.sort { lhs, rhs in
            lhs.time == rhs.time
                ? reasonPriority(lhs.reason) < reasonPriority(rhs.reason)
                : lhs.time < rhs.time
        }
        return deduplicated(combined)
    }

    private func reasonPriority(_ reason: AutoEditPlan.CameraKeyframe.Reason) -> Int {
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

    private func appendExit(
        after click: ClickEvent,
        before nextClickTime: Double?,
        duration: Double,
        overview: TracePoint,
        to keyframes: inout [AutoEditPlan.CameraKeyframe]
    ) {
        let latestCenter = keyframes.last?.center ?? overview
        var holdTime = click.time + configuration.holdDuration
        var returnTime = holdTime + configuration.returnDuration

        // The complete page is the resting state. If the natural hold would
        // run past the media boundary, shorten the hold while preserving the
        // full return duration. The planner reserves this tail before starting
        // a final zoom, so normal final shots never need an abrupt reset.
        if nextClickTime == nil, returnTime > duration {
            returnTime = duration
            let focusCompletionTime = keyframes.last?.time ?? click.time
            holdTime = max(
                click.time,
                focusCompletionTime,
                returnTime - configuration.returnDuration
            )
        }

        if let nextClickTime {
            returnTime = min(returnTime, max(click.time, nextClickTime - 0.08))
            holdTime = min(holdTime, max(click.time, returnTime - configuration.returnDuration))
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
            easing: "critically-damped",
            reason: .returnToOverview
        ), to: &keyframes)
    }

    private func shouldReturnToOverview(
        after click: ClickEvent,
        before nextClickTime: Double
    ) -> Bool {
        guard nextClickTime - click.time > configuration.followWindow else {
            return false
        }
        let naturalReturnTime = click.time
            + configuration.holdDuration
            + configuration.returnDuration
        return naturalReturnTime + configuration.minimumOverviewDwell
            <= nextClickTime
    }

    /// A fixed duration makes a tiny nudge and a cross-screen reframe travel at
    /// radically different perceived speeds. Distance-aware timing applies the
    /// same motion budget to every click shot while retaining a bounded delay
    /// for rapid demonstrations.
    private func transitionDuration(
        from state: CameraFrameState,
        toScale: Double,
        center: TracePoint
    ) -> Double {
        let centerDistance = hypot(
            center.x - state.center.x,
            center.y - state.center.y
        )
        let panDuration = centerDistance / configuration.maximumPanSpeed
        let zoomDistance = abs(log2(max(toScale, 1) / max(state.scale, 1)))
        // Quintic smootherstep peaks at 1.875× its average slope. Budget the
        // peak instead of only the endpoint duration; otherwise a nominally
        // slow 0.82 s zoom still surges in its middle frames.
        let zoomDuration = zoomDistance * 1.875
            / configuration.maximumZoomVelocity
        return min(
            max(configuration.zoomDuration, panDuration, zoomDuration),
            configuration.maximumTransitionDuration
        )
    }

    private func isInsideClickFocusSafeArea(
        _ point: TracePoint,
        focusCenter: TracePoint
    ) -> Bool {
        let visibleHalf = 0.5 / max(configuration.focusScale, 1)
        let safeHalf = visibleHalf * configuration.clickFocusSafeArea
        return abs(point.x - focusCenter.x) <= safeHalf
            && abs(point.y - focusCenter.y) <= safeHalf
    }

    private func scrollLockRanges(
        pointerEvents: [PointerEvent],
        duration: Double
    ) -> [ClosedRange<Double>] {
        let times = pointerEvents
            .filter { $0.kind == .scroll && $0.time >= 0 && $0.time <= duration }
            .map(\.time)
            .sorted()
        guard let first = times.first else { return [] }

        var ranges: [ClosedRange<Double>] = []
        var start = first
        var end = first
        for time in times.dropFirst() {
            if time - end <= configuration.scrollActivityGap {
                end = time
            } else {
                ranges.append(
                    start...min(end + configuration.scrollSettleDelay, duration)
                )
                start = time
                end = time
            }
        }
        ranges.append(start...min(end + configuration.scrollSettleDelay, duration))
        return ranges
    }

    private func isLocked(
        _ time: Double,
        by ranges: [ClosedRange<Double>]
    ) -> Bool {
        ranges.contains { $0.contains(time) }
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
