import Foundation

public enum ScreenshotAnnotationResizeHandle: String, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case arrowStart
    case arrowEnd
}

/// Platform-neutral hit testing and transforms for non-destructive screenshot annotations.
public enum ScreenshotAnnotationGeometry {
    public static func topmostAnnotationID(
        in annotations: [ScreenshotAnnotation],
        at point: TracePoint,
        tolerance: Double = 0.012
    ) -> UUID? {
        annotations.reversed().first {
            contains($0, point: point, tolerance: max(tolerance, 0))
        }?.id
    }

    public static func resizeHandle(
        for annotation: ScreenshotAnnotation,
        at location: TracePoint,
        tolerance: Double = 0.018
    ) -> ScreenshotAnnotationResizeHandle? {
        applicableHandles(for: annotation).first { handle in
            guard let handlePoint = point(for: handle, annotation: annotation) else { return false }
            return hypot(location.x - handlePoint.x, location.y - handlePoint.y) <= max(tolerance, 0)
        }
    }

    public static func point(
        for handle: ScreenshotAnnotationResizeHandle,
        annotation: ScreenshotAnnotation
    ) -> TracePoint? {
        if annotation.kind == .arrow {
            switch handle {
            case .arrowStart:
                return annotation.start
            case .arrowEnd:
                return annotation.end
            default:
                return nil
            }
        }

        let bounds = annotation.bounds
        switch handle {
        case .topLeft:
            return TracePoint(x: bounds.x, y: bounds.y)
        case .topRight:
            return TracePoint(x: bounds.x + bounds.width, y: bounds.y)
        case .bottomLeft:
            return TracePoint(x: bounds.x, y: bounds.y + bounds.height)
        case .bottomRight:
            return TracePoint(x: bounds.x + bounds.width, y: bounds.y + bounds.height)
        case .arrowStart, .arrowEnd:
            return nil
        }
    }

    public static func moved(
        _ annotation: ScreenshotAnnotation,
        byX requestedDeltaX: Double,
        y requestedDeltaY: Double
    ) -> ScreenshotAnnotation {
        var result = annotation
        let bounds = annotation.bounds
        let deltaX = min(
            max(requestedDeltaX, -bounds.x),
            max(1 - bounds.x - bounds.width, -bounds.x)
        )
        let deltaY = min(
            max(requestedDeltaY, -bounds.y),
            max(1 - bounds.y - bounds.height, -bounds.y)
        )
        result.bounds = TraceRect(
            x: bounds.x + deltaX,
            y: bounds.y + deltaY,
            width: bounds.width,
            height: bounds.height
        )
        if let start = annotation.start {
            result.start = TracePoint(x: start.x + deltaX, y: start.y + deltaY)
        }
        if let end = annotation.end {
            result.end = TracePoint(x: end.x + deltaX, y: end.y + deltaY)
        }
        if let points = annotation.points {
            result.points = points.map {
                TracePoint(x: $0.x + deltaX, y: $0.y + deltaY)
            }
        }
        return result
    }

    public static func resized(
        _ annotation: ScreenshotAnnotation,
        handle: ScreenshotAnnotationResizeHandle,
        to requestedPoint: TracePoint,
        minimumExtent: Double = 0.006
    ) -> ScreenshotAnnotation {
        let point = clamped(requestedPoint)
        let minimumExtent = min(max(minimumExtent, 0.001), 0.25)
        if annotation.kind == .arrow {
            return resizedArrow(
                annotation,
                handle: handle,
                to: point,
                minimumExtent: minimumExtent
            )
        }

        let original = annotation.bounds
        let maxX = min(max(original.x + original.width, minimumExtent), 1)
        let maxY = min(max(original.y + original.height, minimumExtent), 1)
        let minX = min(max(original.x, 0), 1 - minimumExtent)
        let minY = min(max(original.y, 0), 1 - minimumExtent)
        let resizedBounds: TraceRect

        switch handle {
        case .topLeft:
            let x = min(max(point.x, 0), maxX - minimumExtent)
            let y = min(max(point.y, 0), maxY - minimumExtent)
            resizedBounds = TraceRect(x: x, y: y, width: maxX - x, height: maxY - y)
        case .topRight:
            let x = max(min(point.x, 1), minX + minimumExtent)
            let y = min(max(point.y, 0), maxY - minimumExtent)
            resizedBounds = TraceRect(x: minX, y: y, width: x - minX, height: maxY - y)
        case .bottomLeft:
            let x = min(max(point.x, 0), maxX - minimumExtent)
            let y = max(min(point.y, 1), minY + minimumExtent)
            resizedBounds = TraceRect(x: x, y: minY, width: maxX - x, height: y - minY)
        case .bottomRight:
            let x = max(min(point.x, 1), minX + minimumExtent)
            let y = max(min(point.y, 1), minY + minimumExtent)
            resizedBounds = TraceRect(x: minX, y: minY, width: x - minX, height: y - minY)
        case .arrowStart, .arrowEnd:
            return annotation
        }

        var result = annotation
        result.bounds = resizedBounds
        if let points = annotation.points {
            result.points = remapped(
                points,
                from: original,
                to: resizedBounds,
                minimumExtent: minimumExtent
            )
        }
        if annotation.kind == .text {
            let scale = resizedBounds.height / max(original.height, minimumExtent)
            result.style.fontSize = min(max(annotation.style.fontSize * scale, 0.012), 0.25)
        }
        return result
    }

    public static func bounds(
        from start: TracePoint,
        to end: TracePoint,
        minimumExtent: Double = 0.006
    ) -> TraceRect {
        let start = clamped(start)
        let end = clamped(end)
        let minimumExtent = min(max(minimumExtent, 0.001), 0.25)
        let width = max(abs(end.x - start.x), minimumExtent)
        let height = max(abs(end.y - start.y), minimumExtent)
        return TraceRect(
            x: min(min(start.x, end.x), 1 - width),
            y: min(min(start.y, end.y), 1 - height),
            width: width,
            height: height
        )
    }

    public static func bounds(
        for points: [TracePoint],
        minimumExtent: Double = 0.006
    ) -> TraceRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return bounds(
            from: TracePoint(x: minX, y: minY),
            to: TracePoint(x: maxX, y: maxY),
            minimumExtent: minimumExtent
        )
    }

    private static func applicableHandles(
        for annotation: ScreenshotAnnotation
    ) -> [ScreenshotAnnotationResizeHandle] {
        annotation.kind == .arrow
            ? [.arrowStart, .arrowEnd]
            : [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    private static func contains(
        _ annotation: ScreenshotAnnotation,
        point: TracePoint,
        tolerance: Double
    ) -> Bool {
        if annotation.kind == .arrow {
            let start = annotation.start
                ?? TracePoint(x: annotation.bounds.x, y: annotation.bounds.y)
            let end = annotation.end
                ?? TracePoint(
                    x: annotation.bounds.x + annotation.bounds.width,
                    y: annotation.bounds.y + annotation.bounds.height
                )
            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance
        }
        if annotation.kind == .freehand, let points = annotation.points {
            if points.count == 1 {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance
            }
            return zip(points, points.dropFirst()).contains { start, end in
                distance(from: point, toSegmentFrom: start, to: end) <= tolerance
            }
        }
        return point.x >= annotation.bounds.x - tolerance
            && point.x <= annotation.bounds.x + annotation.bounds.width + tolerance
            && point.y >= annotation.bounds.y - tolerance
            && point.y <= annotation.bounds.y + annotation.bounds.height + tolerance
    }

    private static func resizedArrow(
        _ annotation: ScreenshotAnnotation,
        handle: ScreenshotAnnotationResizeHandle,
        to point: TracePoint,
        minimumExtent: Double
    ) -> ScreenshotAnnotation {
        guard var start = annotation.start, var end = annotation.end else { return annotation }
        switch handle {
        case .arrowStart:
            start = point
        case .arrowEnd:
            end = point
        default:
            return annotation
        }
        guard hypot(end.x - start.x, end.y - start.y) >= minimumExtent else {
            return annotation
        }
        var result = annotation
        result.start = start
        result.end = end
        result.bounds = bounds(from: start, to: end, minimumExtent: minimumExtent)
        return result
    }

    private static func distance(
        from point: TracePoint,
        toSegmentFrom start: TracePoint,
        to end: TracePoint
    ) -> Double {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > .ulpOfOne else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = min(
            max(((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared, 0),
            1
        )
        let nearest = TracePoint(
            x: start.x + projection * deltaX,
            y: start.y + projection * deltaY
        )
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private static func clamped(_ point: TracePoint) -> TracePoint {
        TracePoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }

    private static func remapped(
        _ points: [TracePoint],
        from source: TraceRect,
        to destination: TraceRect,
        minimumExtent: Double
    ) -> [TracePoint] {
        let sourceWidth = max(source.width, minimumExtent)
        let sourceHeight = max(source.height, minimumExtent)
        return points.map { point in
            let relativeX = (point.x - source.x) / sourceWidth
            let relativeY = (point.y - source.y) / sourceHeight
            return TracePoint(
                x: min(max(destination.x + relativeX * destination.width, 0), 1),
                y: min(max(destination.y + relativeY * destination.height, 0), 1)
            )
        }
    }
}
