import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureServiceError: LocalizedError {
    case unsupportedSystem
    case emptySelection
    case noImageReturned

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "当前 macOS 版本不支持这条截图管线。"
        case .emptySelection:
            return "截图选区为空。"
        case .noImageReturned:
            return "系统没有返回截图图像。"
        }
    }
}

struct ScreenCaptureService: Sendable {
    func capture(globalDisplayRect: CGRect) async throws -> CGImage {
        guard globalDisplayRect.width >= 1, globalDisplayRect.height >= 1 else {
            throw ScreenCaptureServiceError.emptySelection
        }
        guard #available(macOS 15.2, *) else {
            throw ScreenCaptureServiceError.unsupportedSystem
        }

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: globalDisplayRect) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScreenCaptureServiceError.noImageReturned)
                }
            }
        }
    }
}
