import Foundation

/// Viewer-centered motion limits. Pan is measured in visible viewport lengths
/// per second, so the same source-space movement becomes stricter while zoomed
/// in. Zoom is measured in octaves per second to treat 1×→2× and 2×→4× equally.
public struct CameraMotionComfortLimits: Equatable, Sendable {
    public let samplesPerSecond: Double
    public let maximumPanVelocity: Double
    public let maximumZoomVelocity: Double
    public let maximumCombinedMotionRatio: Double
    public let reversalWindowSeconds: Double
    public let maximumRapidReversalsPerTenSeconds: Int
    public let minimumReturnDurationSeconds: Double

    public init(
        samplesPerSecond: Double = 120,
        maximumPanVelocity: Double,
        maximumZoomVelocity: Double,
        maximumCombinedMotionRatio: Double,
        reversalWindowSeconds: Double,
        maximumRapidReversalsPerTenSeconds: Int,
        minimumReturnDurationSeconds: Double
    ) {
        self.samplesPerSecond = min(max(
            samplesPerSecond.isFinite ? samplesPerSecond : 120,
            30
        ), 240)
        self.maximumPanVelocity = max(
            maximumPanVelocity.isFinite ? maximumPanVelocity : 0.75,
            0.05
        )
        self.maximumZoomVelocity = max(
            maximumZoomVelocity.isFinite ? maximumZoomVelocity : 1.25,
            0.05
        )
        self.maximumCombinedMotionRatio = max(
            maximumCombinedMotionRatio.isFinite ? maximumCombinedMotionRatio : 1.35,
            0.5
        )
        self.reversalWindowSeconds = max(
            reversalWindowSeconds.isFinite ? reversalWindowSeconds : 1,
            0
        )
        self.maximumRapidReversalsPerTenSeconds = max(
            maximumRapidReversalsPerTenSeconds,
            0
        )
        self.minimumReturnDurationSeconds = max(
            minimumReturnDurationSeconds.isFinite ? minimumReturnDurationSeconds : 0.9,
            0
        )
    }

    public static func recommended(
        for strength: AutoEditPlan.Camera.GenerationStrength
    ) -> Self {
        switch strength {
        case .restrained:
            Self(
                maximumPanVelocity: 0.75,
                maximumZoomVelocity: 1.25,
                maximumCombinedMotionRatio: 1.35,
                reversalWindowSeconds: 1.25,
                maximumRapidReversalsPerTenSeconds: 2,
                minimumReturnDurationSeconds: 0.95
            )
        case .balanced:
            Self(
                maximumPanVelocity: 1.00,
                maximumZoomVelocity: 1.60,
                maximumCombinedMotionRatio: 1.45,
                reversalWindowSeconds: 0.95,
                maximumRapidReversalsPerTenSeconds: 3,
                minimumReturnDurationSeconds: 0.72
            )
        case .active:
            Self(
                maximumPanVelocity: 1.40,
                maximumZoomVelocity: 2.40,
                maximumCombinedMotionRatio: 1.60,
                reversalWindowSeconds: 0.70,
                maximumRapidReversalsPerTenSeconds: 4,
                minimumReturnDurationSeconds: 0.50
            )
        }
    }
}

public enum CameraMotionComfortIssue: String, Codable, Equatable, Hashable, Sendable {
    case excessivePanVelocity
    case excessiveZoomVelocity
    case excessiveCombinedMotion
    case rapidDirectionReversals
    case compressedReturn
}

public struct CameraMotionComfortReport: Codable, Equatable, Sendable {
    public let maximumPanVelocity: Double
    public let maximumZoomVelocity: Double
    public let maximumCombinedMotionRatio: Double
    public let rapidDirectionReversalCount: Int
    public let compressedReturnCount: Int
    public let analyzedTransitionCount: Int
    public let issues: [CameraMotionComfortIssue]

    public var isComfortable: Bool { issues.isEmpty }

    public init(
        maximumPanVelocity: Double,
        maximumZoomVelocity: Double,
        maximumCombinedMotionRatio: Double,
        rapidDirectionReversalCount: Int,
        compressedReturnCount: Int,
        analyzedTransitionCount: Int,
        issues: [CameraMotionComfortIssue]
    ) {
        self.maximumPanVelocity = max(
            maximumPanVelocity.isFinite ? maximumPanVelocity : 0,
            0
        )
        self.maximumZoomVelocity = max(
            maximumZoomVelocity.isFinite ? maximumZoomVelocity : 0,
            0
        )
        self.maximumCombinedMotionRatio = max(
            maximumCombinedMotionRatio.isFinite ? maximumCombinedMotionRatio : 0,
            0
        )
        self.rapidDirectionReversalCount = max(rapidDirectionReversalCount, 0)
        self.compressedReturnCount = max(compressedReturnCount, 0)
        self.analyzedTransitionCount = max(analyzedTransitionCount, 0)
        self.issues = Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
    }
}

public enum CameraMotionComfortAnalyzer {
    public static func analyze(
        camera: AutoEditPlan.Camera,
        durationSeconds: Double,
        limits requestedLimits: CameraMotionComfortLimits? = nil
    ) -> CameraMotionComfortReport {
        let limits = requestedLimits ?? .recommended(for: camera.generationStrength)
        return analyze(
            keyframes: EffectTimeline.effectiveCameraKeyframes(for: camera),
            durationSeconds: durationSeconds,
            limits: limits
        )
    }

    public static func analyze(
        keyframes requestedKeyframes: [AutoEditPlan.CameraKeyframe],
        durationSeconds requestedDuration: Double,
        limits: CameraMotionComfortLimits
    ) -> CameraMotionComfortReport {
        let keyframes = requestedKeyframes
            .filter { $0.time.isFinite && $0.time >= 0 }
            .sorted { lhs, rhs in
                lhs.time == rhs.time
                    ? lhs.reason.rawValue < rhs.reason.rawValue
                    : lhs.time < rhs.time
            }
        guard keyframes.count >= 2 else { return emptyReport }
        let duration = max(
            requestedDuration.isFinite ? requestedDuration : 0,
            keyframes.last?.time ?? 0
        )

        var maximumPanVelocity = 0.0
        var maximumZoomVelocity = 0.0
        var maximumCombinedMotionRatio = 0.0
        var analyzedTransitionCount = 0
        var compressedReturnCount = 0
        var rapidDirectionReversalCount = 0
        var previousMovingDirection: LensPoint?
        var previousMovingEndTime: Double?

        for (startFrame, endFrame) in zip(keyframes, keyframes.dropFirst()) {
            let startTime = min(max(startFrame.time, 0), duration)
            let endTime = min(max(endFrame.time, startTime), duration)
            let transitionDuration = endTime - startTime
            guard transitionDuration > 0.000_1 else { continue }

            let startState = EffectTimeline.cameraState(
                at: startTime,
                keyframes: keyframes
            )
            let endState = EffectTimeline.cameraState(
                at: endTime,
                keyframes: keyframes
            )
            let delta = LensPoint(
                x: endState.center.x - startState.center.x,
                y: endState.center.y - startState.center.y
            )
            let averageScale = max((startState.scale + endState.scale) / 2, 1)
            let panTravel = hypot(delta.x, delta.y) * averageScale
            let zoomTravel = abs(log2(
                max(endState.scale, 0.000_1) / max(startState.scale, 0.000_1)
            ))
            guard panTravel > 0.000_1 || zoomTravel > 0.000_1 else { continue }
            analyzedTransitionCount += 1

            if endFrame.reason == .returnToOverview,
               transitionDuration + 0.000_1 < limits.minimumReturnDurationSeconds {
                compressedReturnCount += 1
            }

            // A deliberate return to the overview closes a shot; it is not the
            // same visual defect as bouncing between opposing focus targets.
            if panTravel >= 0.06, endFrame.reason != .returnToOverview {
                let length = max(hypot(delta.x, delta.y), 0.000_001)
                let direction = LensPoint(x: delta.x / length, y: delta.y / length)
                if let previousMovingDirection,
                   let previousMovingEndTime,
                   startTime - previousMovingEndTime <= limits.reversalWindowSeconds {
                    let dot = direction.x * previousMovingDirection.x
                        + direction.y * previousMovingDirection.y
                    if dot < -0.5 {
                        rapidDirectionReversalCount += 1
                    }
                }
                previousMovingDirection = direction
                previousMovingEndTime = endTime
            }

            let sampleCount = max(
                Int(ceil(transitionDuration * limits.samplesPerSecond)),
                2
            )
            var previousTime = startTime
            var previousState = startState
            for sampleIndex in 1...sampleCount {
                let time = startTime
                    + transitionDuration * Double(sampleIndex) / Double(sampleCount)
                let state = EffectTimeline.cameraState(at: time, keyframes: keyframes)
                let elapsed = max(time - previousTime, 0.000_001)
                let visibleScale = max((previousState.scale + state.scale) / 2, 1)
                let panVelocity = hypot(
                    state.center.x - previousState.center.x,
                    state.center.y - previousState.center.y
                ) * visibleScale / elapsed
                let zoomVelocity = abs(log2(
                    max(state.scale, 0.000_1) / max(previousState.scale, 0.000_1)
                )) / elapsed
                let combinedMotionRatio = hypot(
                    panVelocity / limits.maximumPanVelocity,
                    zoomVelocity / limits.maximumZoomVelocity
                )
                maximumPanVelocity = max(maximumPanVelocity, panVelocity)
                maximumZoomVelocity = max(maximumZoomVelocity, zoomVelocity)
                maximumCombinedMotionRatio = max(
                    maximumCombinedMotionRatio,
                    combinedMotionRatio
                )
                previousTime = time
                previousState = state
            }
        }

        var issues: [CameraMotionComfortIssue] = []
        if maximumPanVelocity > limits.maximumPanVelocity * 1.02 {
            issues.append(.excessivePanVelocity)
        }
        if maximumZoomVelocity > limits.maximumZoomVelocity * 1.02 {
            issues.append(.excessiveZoomVelocity)
        }
        if maximumCombinedMotionRatio > limits.maximumCombinedMotionRatio * 1.02 {
            issues.append(.excessiveCombinedMotion)
        }
        let reversalWindows = max(Int(ceil(duration / 10)), 1)
        if rapidDirectionReversalCount
            > reversalWindows * limits.maximumRapidReversalsPerTenSeconds {
            issues.append(.rapidDirectionReversals)
        }
        if compressedReturnCount > 0 {
            issues.append(.compressedReturn)
        }
        return CameraMotionComfortReport(
            maximumPanVelocity: maximumPanVelocity,
            maximumZoomVelocity: maximumZoomVelocity,
            maximumCombinedMotionRatio: maximumCombinedMotionRatio,
            rapidDirectionReversalCount: rapidDirectionReversalCount,
            compressedReturnCount: compressedReturnCount,
            analyzedTransitionCount: analyzedTransitionCount,
            issues: issues
        )
    }

    private static let emptyReport = CameraMotionComfortReport(
        maximumPanVelocity: 0,
        maximumZoomVelocity: 0,
        maximumCombinedMotionRatio: 0,
        rapidDirectionReversalCount: 0,
        compressedReturnCount: 0,
        analyzedTransitionCount: 0,
        issues: []
    )
}
