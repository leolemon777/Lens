import CoreGraphics
import Foundation

/// Screenshot modes shared by the macOS capture UI and the future Windows adapter.
public enum ScreenshotCaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case display
}

public enum RecordingCaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case display
}

public struct RecordingCaptureSource: Equatable, Sendable {
    public let mode: RecordingCaptureMode
    public let displayID: UInt32?
    public let windowID: UInt32?
    /// Display-local source rectangle in logical points. Only present for region capture.
    public let sourceRect: CGRect?
    /// Global top-left capture bounds in logical points, used by event normalization.
    public let captureBounds: CGRect
    public let windowTitle: String?
    public let applicationName: String?

    public init(
        mode: RecordingCaptureMode,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        sourceRect: CGRect? = nil,
        captureBounds: CGRect,
        windowTitle: String? = nil,
        applicationName: String? = nil
    ) {
        self.mode = mode
        self.displayID = displayID
        self.windowID = windowID
        self.sourceRect = sourceRect?.standardized
        self.captureBounds = captureBounds.standardized
        self.windowTitle = windowTitle
        self.applicationName = applicationName
    }
}

/// Platform-neutral description used to resolve overlapping windows before capture.
public struct WindowSelectionCandidate: Identifiable, Sendable {
    public let id: UInt32
    public let globalFrame: CGRect
    /// Lower values are closer to the user, matching CGWindowList's front-to-back order.
    public let frontToBackOrder: Int
    public let title: String
    public let applicationName: String

    public init(
        id: UInt32,
        globalFrame: CGRect,
        frontToBackOrder: Int,
        title: String,
        applicationName: String
    ) {
        self.id = id
        self.globalFrame = globalFrame.standardized
        self.frontToBackOrder = frontToBackOrder
        self.title = title
        self.applicationName = applicationName
    }
}

public enum CaptureGeometry {
    public static func globalRect(fromLocalRect localRect: CGRect, displayBounds: CGRect) -> CGRect {
        let local = localRect.standardized
        return CGRect(
            x: displayBounds.minX + local.minX,
            y: displayBounds.minY + local.minY,
            width: local.width,
            height: local.height
        ).standardized
    }

    public static func globalPoint(fromLocalPoint point: CGPoint, displayBounds: CGRect) -> CGPoint {
        CGPoint(x: displayBounds.minX + point.x, y: displayBounds.minY + point.y)
    }

    /// Returns the visible part of a global rectangle in display-local, top-left display space.
    public static func localIntersection(of globalRect: CGRect, displayBounds: CGRect) -> CGRect? {
        let intersection = globalRect.standardized.intersection(displayBounds.standardized)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }
        return intersection.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    public static func topmostWindow(
        at globalPoint: CGPoint,
        candidates: [WindowSelectionCandidate]
    ) -> WindowSelectionCandidate? {
        candidates
            .filter { $0.globalFrame.contains(globalPoint) }
            .min { lhs, rhs in
                if lhs.frontToBackOrder != rhs.frontToBackOrder {
                    return lhs.frontToBackOrder < rhs.frontToBackOrder
                }
                let lhsArea = lhs.globalFrame.width * lhs.globalFrame.height
                let rhsArea = rhs.globalFrame.width * rhs.globalFrame.height
                if lhsArea != rhsArea {
                    return lhsArea < rhsArea
                }
                return lhs.id < rhs.id
            }
    }

    public static func displayRecordingSource(
        displayID: UInt32,
        displayBounds: CGRect
    ) -> RecordingCaptureSource {
        RecordingCaptureSource(
            mode: .display,
            displayID: displayID,
            captureBounds: displayBounds
        )
    }

    public static func regionRecordingSource(
        displayID: UInt32,
        localRect: CGRect,
        displayBounds: CGRect,
        minimumExtent: CGFloat = 3
    ) -> RecordingCaptureSource? {
        let localDisplayBounds = CGRect(origin: .zero, size: displayBounds.standardized.size)
        let clipped = localRect.standardized.intersection(localDisplayBounds)
        guard !clipped.isNull,
              clipped.width >= minimumExtent,
              clipped.height >= minimumExtent else {
            return nil
        }
        return RecordingCaptureSource(
            mode: .region,
            displayID: displayID,
            sourceRect: clipped,
            captureBounds: globalRect(fromLocalRect: clipped, displayBounds: displayBounds)
        )
    }

    public static func windowRecordingSource(
        _ candidate: WindowSelectionCandidate
    ) -> RecordingCaptureSource {
        RecordingCaptureSource(
            mode: .window,
            windowID: candidate.id,
            captureBounds: candidate.globalFrame,
            windowTitle: candidate.title,
            applicationName: candidate.applicationName
        )
    }

    public static func recordingPixelDimensions(
        pointSize: CGSize,
        pointPixelScale: CGFloat
    ) -> TraceDimensions {
        func evenDimension(_ points: CGFloat) -> Int {
            let raw = max(Int(ceil(points * max(pointPixelScale, 1))), 2)
            return raw.isMultiple(of: 2) ? raw : raw + 1
        }
        return TraceDimensions(
            width: evenDimension(max(pointSize.width, 0)),
            height: evenDimension(max(pointSize.height, 0))
        )
    }

    public static func normalizedPoint(
        _ globalPoint: CGPoint,
        in captureBounds: CGRect
    ) -> TracePoint? {
        let bounds = captureBounds.standardized
        guard bounds.width > 0,
              bounds.height > 0,
              globalPoint.x >= bounds.minX,
              globalPoint.x <= bounds.maxX,
              globalPoint.y >= bounds.minY,
              globalPoint.y <= bounds.maxY else {
            return nil
        }
        return TracePoint(
            x: min(max((globalPoint.x - bounds.minX) / bounds.width, 0), 1),
            y: min(max((globalPoint.y - bounds.minY) / bounds.height, 0), 1)
        )
    }
}
