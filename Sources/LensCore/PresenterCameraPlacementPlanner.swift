import Foundation

public struct PresenterCameraFrameState: Equatable, Sendable {
    /// Output-normalized center using a top-left origin.
    public let center: LensPoint
    /// Width as a fraction of the output canvas.
    public let size: Double

    public init(center: LensPoint, size: Double) {
        self.center = center
        self.size = size
    }
}

public enum PresenterCameraPlacementPlanner {
    public static func state(
        atSourceTime sourceTime: Double,
        layout: AutoEditPlan.PresenterCamera,
        cameraKeyframes: [AutoEditPlan.CameraKeyframe] = [],
        captions: AutoEditPlan.Captions? = nil,
        captionAvoidanceAmount: Double = 1,
        canvasAspectRatio: Double = 16.0 / 9.0
    ) -> PresenterCameraFrameState {
        let aspectRatio = max(
            canvasAspectRatio.isFinite ? canvasAspectRatio : 16.0 / 9.0,
            0.1
        )
        let safeSourceTime = max(sourceTime.isFinite ? sourceTime : 0, 0)
        let requested = interpolatedState(
            at: safeSourceTime,
            layout: layout,
            aspectRatio: aspectRatio
        )
        let preferred = clamped(
            requested,
            shape: layout.shape,
            margin: layout.margin,
            aspectRatio: aspectRatio
        )
        guard layout.automaticallyAvoidsContent else { return preferred }

        let camera = EffectTimeline.cameraState(
            at: safeSourceTime,
            keyframes: cameraKeyframes
        )
        let outputFocus = outputFocus(for: camera)
        let focusAmount = min(max((camera.scale - 1) / 0.42, 0), 1)
        let captionConflict = overlapsCaption(
            state: preferred,
            shape: layout.shape,
            captions: captions,
            aspectRatio: aspectRatio
        )
        let captionAmount = captions == nil ? 0 : min(max(
            captionAvoidanceAmount.isFinite ? captionAvoidanceAmount : 1,
            0
        ), 1)
        guard focusAmount > 0.015 || (captionConflict && captionAmount > 0.001) else {
            return preferred
        }

        let candidates = cornerStates(
            size: preferred.size,
            shape: layout.shape,
            margin: layout.margin,
            aspectRatio: aspectRatio
        )
        let best = candidates.max { lhs, rhs in
            score(
                lhs,
                preferred: preferred,
                focus: outputFocus,
                focusAmount: focusAmount,
                captions: captions,
                shape: layout.shape,
                aspectRatio: aspectRatio
            ) < score(
                rhs,
                preferred: preferred,
                focus: outputFocus,
                focusAmount: focusAmount,
                captions: captions,
                shape: layout.shape,
                aspectRatio: aspectRatio
            )
        } ?? preferred
        let progress = max(
            smoothStep(focusAmount),
            captionConflict ? smoothStep(captionAmount) : 0
        )
        return clamped(
            PresenterCameraFrameState(
                center: LensPoint(
                    x: lerp(preferred.center.x, best.center.x, progress),
                    y: lerp(preferred.center.y, best.center.y, progress)
                ),
                size: lerp(preferred.size, best.size, progress)
            ),
            shape: layout.shape,
            margin: layout.margin,
            aspectRatio: aspectRatio
        )
    }

    private static func interpolatedState(
        at time: Double,
        layout: AutoEditPlan.PresenterCamera,
        aspectRatio: Double
    ) -> PresenterCameraFrameState {
        let base = PresenterCameraFrameState(
            center: layout.position ?? anchorCenter(
                layout.anchor,
                size: layout.size,
                shape: layout.shape,
                margin: layout.margin,
                aspectRatio: aspectRatio
            ),
            size: layout.size
        )
        let keyframes = layout.keyframes.sorted {
            $0.sourceTimeSeconds < $1.sourceTimeSeconds
        }
        guard let first = keyframes.first else { return base }
        if time <= first.sourceTimeSeconds {
            guard first.sourceTimeSeconds > 0 else {
                return PresenterCameraFrameState(center: first.center, size: first.size)
            }
            return interpolate(
                from: base,
                at: 0,
                to: first,
                at: time
            )
        }
        guard let nextIndex = keyframes.firstIndex(where: {
            $0.sourceTimeSeconds >= time
        }) else {
            guard let last = keyframes.last else { return base }
            return PresenterCameraFrameState(center: last.center, size: last.size)
        }
        let previous = keyframes[nextIndex - 1]
        return interpolate(
            from: PresenterCameraFrameState(center: previous.center, size: previous.size),
            at: previous.sourceTimeSeconds,
            to: keyframes[nextIndex],
            at: time
        )
    }

    private static func interpolate(
        from start: PresenterCameraFrameState,
        at startTime: Double,
        to end: AutoEditPlan.PresenterCameraKeyframe,
        at time: Double
    ) -> PresenterCameraFrameState {
        let duration = max(end.sourceTimeSeconds - startTime, 0.000_001)
        let linear = min(max((time - startTime) / duration, 0), 1)
        let progress = eased(linear, easing: end.easing)
        return PresenterCameraFrameState(
            center: LensPoint(
                x: lerp(start.center.x, end.center.x, progress),
                y: lerp(start.center.y, end.center.y, progress)
            ),
            size: lerp(start.size, end.size, progress)
        )
    }

    private static func cornerStates(
        size: Double,
        shape: AutoEditPlan.PresenterCamera.Shape,
        margin: Double,
        aspectRatio: Double
    ) -> [PresenterCameraFrameState] {
        let safeMargin = min(max(margin, 0), 0.20)
        let width = safeWidth(
            size,
            shape: shape,
            margin: safeMargin,
            aspectRatio: aspectRatio
        )
        let height = normalizedHeight(width, shape: shape, aspectRatio: aspectRatio)
        let left = safeMargin + width / 2
        let right = 1 - safeMargin - width / 2
        let top = safeMargin + height / 2
        let bottom = 1 - safeMargin - height / 2
        return [
            PresenterCameraFrameState(center: LensPoint(x: left, y: top), size: width),
            PresenterCameraFrameState(center: LensPoint(x: right, y: top), size: width),
            PresenterCameraFrameState(center: LensPoint(x: left, y: bottom), size: width),
            PresenterCameraFrameState(center: LensPoint(x: right, y: bottom), size: width)
        ]
    }

    private static func anchorCenter(
        _ anchor: AutoEditPlan.PresenterCamera.Anchor,
        size: Double,
        shape: AutoEditPlan.PresenterCamera.Shape,
        margin: Double,
        aspectRatio: Double
    ) -> LensPoint {
        let corners = cornerStates(
            size: size,
            shape: shape,
            margin: margin,
            aspectRatio: aspectRatio
        )
        return switch anchor {
        case .topLeading: corners[0].center
        case .topTrailing: corners[1].center
        case .bottomLeading: corners[2].center
        case .bottomTrailing: corners[3].center
        }
    }

    private static func clamped(
        _ state: PresenterCameraFrameState,
        shape: AutoEditPlan.PresenterCamera.Shape,
        margin: Double,
        aspectRatio: Double
    ) -> PresenterCameraFrameState {
        let safeMargin = min(max(margin.isFinite ? margin : 0.035, 0), 0.20)
        let width = safeWidth(
            state.size,
            shape: shape,
            margin: safeMargin,
            aspectRatio: aspectRatio
        )
        let height = normalizedHeight(width, shape: shape, aspectRatio: aspectRatio)
        let minX = min(safeMargin + width / 2, 0.5)
        let maxX = max(1 - safeMargin - width / 2, 0.5)
        let minY = min(safeMargin + height / 2, 0.5)
        let maxY = max(1 - safeMargin - height / 2, 0.5)
        return PresenterCameraFrameState(
            center: LensPoint(
                x: min(max(state.center.x.isFinite ? state.center.x : 0.5, minX), maxX),
                y: min(max(state.center.y.isFinite ? state.center.y : 0.5, minY), maxY)
            ),
            size: width
        )
    }

    private static func normalizedHeight(
        _ width: Double,
        shape: AutoEditPlan.PresenterCamera.Shape,
        aspectRatio: Double
    ) -> Double {
        let pixelRatio = shape == .circle ? 1.0 : 9.0 / 16.0
        return max(width * aspectRatio * pixelRatio, 0.001)
    }

    private static func safeWidth(
        _ requested: Double,
        shape: AutoEditPlan.PresenterCamera.Shape,
        margin: Double,
        aspectRatio: Double
    ) -> Double {
        let requested = min(max(requested.isFinite ? requested : 0.19, 0.08), 0.45)
        let pixelRatio = shape == .circle ? 1.0 : 9.0 / 16.0
        let maximumByHeight = max(
            (1 - 2 * margin) / max(aspectRatio * pixelRatio, 0.001),
            0.001
        )
        return min(requested, maximumByHeight)
    }

    private static func outputFocus(for camera: CameraFrameState) -> LensPoint {
        let scale = max(camera.scale.isFinite ? camera.scale : 1, 1)
        let viewport = 1 / scale
        func coordinate(_ requested: Double) -> Double {
            let requested = min(max(requested.isFinite ? requested : 0.5, 0), 1)
            let origin = min(max(requested - viewport / 2, 0), 1 - viewport)
            return min(max((requested - origin) * scale, 0), 1)
        }
        return LensPoint(
            x: coordinate(camera.center.x),
            y: coordinate(camera.center.y)
        )
    }

    private static func overlapsCaption(
        state: PresenterCameraFrameState,
        shape: AutoEditPlan.PresenterCamera.Shape,
        captions: AutoEditPlan.Captions?,
        aspectRatio: Double
    ) -> Bool {
        guard let captions, captions.isEnabled else { return false }
        let camera = rect(
            for: state,
            shape: shape,
            aspectRatio: aspectRatio
        )
        let caption: CGRect = switch captions.position {
        case .top: CGRect(x: 0.09, y: 0.025, width: 0.82, height: 0.22)
        case .center: CGRect(x: 0.09, y: 0.39, width: 0.82, height: 0.22)
        case .bottom: CGRect(x: 0.09, y: 0.755, width: 0.82, height: 0.22)
        }
        return camera.intersects(caption)
    }

    private static func rect(
        for state: PresenterCameraFrameState,
        shape: AutoEditPlan.PresenterCamera.Shape,
        aspectRatio: Double
    ) -> CGRect {
        let height = normalizedHeight(state.size, shape: shape, aspectRatio: aspectRatio)
        return CGRect(
            x: state.center.x - state.size / 2,
            y: state.center.y - height / 2,
            width: state.size,
            height: height
        )
    }

    private static func score(
        _ candidate: PresenterCameraFrameState,
        preferred: PresenterCameraFrameState,
        focus: LensPoint,
        focusAmount: Double,
        captions: AutoEditPlan.Captions?,
        shape: AutoEditPlan.PresenterCamera.Shape,
        aspectRatio: Double
    ) -> Double {
        let focusDistance = squaredDistance(candidate.center, focus)
        let movement = squaredDistance(candidate.center, preferred.center)
        let captionPenalty = overlapsCaption(
            state: candidate,
            shape: shape,
            captions: captions,
            aspectRatio: aspectRatio
        ) ? 8.0 : 0
        return focusDistance * max(focusAmount, 0.08) * 3.2
            - movement * 0.12
            - captionPenalty
    }

    private static func squaredDistance(_ lhs: LensPoint, _ rhs: LensPoint) -> Double {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        return x * x + y * y
    }

    private static func eased(_ value: Double, easing: String) -> Double {
        switch easing {
        case "linear": return value
        case "ease-in": return value * value
        case "ease-out": return 1 - pow(1 - value, 2)
        case "spring-gentle":
            let smooth = smoothStep(value)
            return 1 - pow(1 - smooth, 1.35)
        default: return smoothStep(value)
        }
    }

    private static func smoothStep(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value * value * (3 - 2 * value)
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }
}
