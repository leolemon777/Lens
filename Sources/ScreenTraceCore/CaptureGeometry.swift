import CoreGraphics
import Foundation

/// Screenshot modes shared by the macOS capture UI and the future Windows adapter.
public enum ScreenshotCaptureMode: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case display
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
}
