import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import ScreenTraceCore

enum ScreenCaptureServiceError: LocalizedError {
    case unsupportedSystem
    case emptySelection
    case noImageReturned
    case noEligibleWindows

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "当前 macOS 版本不支持这条截图管线。"
        case .emptySelection:
            return "截图选区为空。"
        case .noImageReturned:
            return "系统没有返回截图图像。"
        case .noEligibleWindows:
            return "当前屏幕上没有可截取的普通窗口。"
        }
    }
}

struct WindowCaptureTarget {
    let window: SCWindow
    let candidate: WindowSelectionCandidate
}

@MainActor
struct ScreenCaptureService {
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

    func capture(window: SCWindow) async throws -> CGImage {
        guard #available(macOS 15.2, *) else {
            throw ScreenCaptureServiceError.unsupportedSystem
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 26.0, *) {
            let configuration = SCScreenshotConfiguration()
            configuration.showsCursor = false
            configuration.ignoreShadows = false
            configuration.includeChildWindows = true
            configuration.dynamicRange = .sdr

            return try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                ) { output, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let image = output?.sdrImage {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: ScreenCaptureServiceError.noImageReturned)
                    }
                }
            }
        }

        let scale = max(CGFloat(filter.pointPixelScale), 1)
        let pointSize = filter.contentRect.size
        guard pointSize.width >= 1, pointSize.height >= 1 else {
            throw ScreenCaptureServiceError.emptySelection
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(ceil(pointSize.width * scale)), 1)
        configuration.height = max(Int(ceil(pointSize.height * scale)), 1)
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.ignoreShadowsSingleWindow = false
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.shouldBeOpaque = false
        configuration.scalesToFit = false

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
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

    func availableWindowTargets(excludingProcessID: pid_t) async throws -> [WindowCaptureTarget] {
        let content = try await shareableContent()
        let order = frontToBackWindowOrder()
        let candidates = content.windows.enumerated().compactMap { fallbackIndex, window -> WindowCaptureTarget? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 48,
                  window.frame.height >= 32,
                  window.owningApplication?.processID != excludingProcessID else {
                return nil
            }

            let appName = window.owningApplication?.applicationName ?? "应用"
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = (title?.isEmpty == false) ? title! : appName
            let candidate = WindowSelectionCandidate(
                id: window.windowID,
                globalFrame: window.frame,
                frontToBackOrder: order[window.windowID] ?? (100_000 + fallbackIndex),
                title: displayTitle,
                applicationName: appName
            )
            return WindowCaptureTarget(window: window, candidate: candidate)
        }
        .sorted { lhs, rhs in
            lhs.candidate.frontToBackOrder < rhs.candidate.frontToBackOrder
        }

        guard !candidates.isEmpty else {
            throw ScreenCaptureServiceError.noEligibleWindows
        }
        return candidates
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: ScreenCaptureServiceError.noEligibleWindows)
                }
            }
        }
    }

    private func frontToBackWindowOrder() -> [CGWindowID: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var result: [CGWindowID: Int] = [:]
        for (index, item) in info.enumerated() {
            guard let number = item[kCGWindowNumber as String] as? NSNumber else { continue }
            result[number.uint32Value] = index
        }
        return result
    }
}
