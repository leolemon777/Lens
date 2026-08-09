import CoreGraphics
import Foundation
import ImageIO
import ScreenTraceCore

enum ScrollingFrameAppendDisposition: Equatable {
    case first
    case appended(deltaPixels: Int, overlapDifference: Double)
    case duplicate(overlapDifference: Double)
    case rejected(bestDifference: Double)
    case limitReached
}

enum VerticalScrollingCaptureAssemblerError: LocalizedError {
    case invalidFrame
    case inconsistentFrameDimensions
    case noFrames
    case unableToDecodeFrame
    case unableToCreateOutput

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "长截图帧尺寸无效。"
        case .inconsistentFrameDimensions: "滚动过程中捕获区域尺寸发生了变化。"
        case .noFrames: "长截图还没有捕获到有效画面。"
        case .unableToDecodeFrame: "无法读取长截图的原始帧。"
        case .unableToCreateOutput: "无法创建拼接后的长截图。"
        }
    }
}

struct ScrollingCaptureAssembly {
    let image: CGImage
    let viewportDimensions: TraceDimensions
    let framePNGs: [Data]
    let frames: [ScrollingCaptureFrame]

    func plan(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect
    ) -> ScrollingCapturePlan {
        ScrollingCapturePlan(
            displayID: displayID,
            sourceRect: TraceRect(
                x: sourceRect.minX,
                y: sourceRect.minY,
                width: sourceRect.width,
                height: sourceRect.height
            ),
            viewportDimensions: viewportDimensions,
            outputDimensions: TraceDimensions(width: image.width, height: image.height),
            frames: frames
        )
    }
}

final class VerticalScrollingCaptureAssembler {
    private struct AcceptedFrame {
        let pngData: Data
        let verticalOffsetPixels: Int
        let appendedHeightPixels: Int
        let overlapDifference: Double
    }

    private let maximumFrames: Int
    private let maximumOutputPixelCount: Int
    private let maximumOutputHeight: Int
    private var acceptedFrames: [AcceptedFrame] = []
    private var lastSignature: FrameSignature?
    private var viewportWidth = 0
    private var viewportHeight = 0
    private(set) var outputHeight = 0

    init(
        maximumFrames: Int = 60,
        maximumOutputPixelCount: Int = 80_000_000,
        maximumOutputHeight: Int = 60_000
    ) {
        self.maximumFrames = max(maximumFrames, 2)
        self.maximumOutputPixelCount = max(maximumOutputPixelCount, 1_000_000)
        self.maximumOutputHeight = max(maximumOutputHeight, 100)
    }

    var acceptedFrameCount: Int { acceptedFrames.count }

    func append(_ image: CGImage) throws -> ScrollingFrameAppendDisposition {
        guard image.width > 0, image.height > 0 else {
            throw VerticalScrollingCaptureAssemblerError.invalidFrame
        }
        if acceptedFrames.isEmpty {
            viewportWidth = image.width
            viewportHeight = image.height
            outputHeight = image.height
            acceptedFrames.append(AcceptedFrame(
                pngData: try ImageEncoding.pngData(from: image),
                verticalOffsetPixels: 0,
                appendedHeightPixels: image.height,
                overlapDifference: 0
            ))
            lastSignature = try FrameSignature(image: image)
            return .first
        }
        guard image.width == viewportWidth, image.height == viewportHeight else {
            throw VerticalScrollingCaptureAssemblerError.inconsistentFrameDimensions
        }
        guard acceptedFrames.count < maximumFrames else { return .limitReached }

        let signature = try FrameSignature(image: image)
        guard let previous = lastSignature else {
            throw VerticalScrollingCaptureAssemblerError.noFrames
        }
        let estimate = previous.estimateDownwardScroll(to: signature)
        if estimate.isDuplicate {
            return .duplicate(overlapDifference: estimate.sameFrameDifference)
        }
        guard let signatureDelta = estimate.deltaRows,
              estimate.bestDifference <= 0.145 else {
            return .rejected(bestDifference: estimate.bestDifference)
        }
        let deltaPixels = min(
            max(Int((Double(signatureDelta) / Double(signature.height)
                * Double(viewportHeight)).rounded()), 1),
            viewportHeight - 1
        )
        let nextOutputHeight = outputHeight + deltaPixels
        let pixelLimitedHeight = max(maximumOutputPixelCount / max(viewportWidth, 1), viewportHeight)
        guard nextOutputHeight <= min(maximumOutputHeight, pixelLimitedHeight) else {
            return .limitReached
        }

        acceptedFrames.append(AcceptedFrame(
            pngData: try ImageEncoding.pngData(from: image),
            verticalOffsetPixels: nextOutputHeight - viewportHeight,
            appendedHeightPixels: deltaPixels,
            overlapDifference: estimate.bestDifference
        ))
        lastSignature = signature
        outputHeight = nextOutputHeight
        return .appended(
            deltaPixels: deltaPixels,
            overlapDifference: estimate.bestDifference
        )
    }

    func render() throws -> ScrollingCaptureAssembly {
        guard !acceptedFrames.isEmpty, viewportWidth > 0, outputHeight > 0 else {
            throw VerticalScrollingCaptureAssemblerError.noFrames
        }
        guard let context = CGContext(
            data: nil,
            width: viewportWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VerticalScrollingCaptureAssemblerError.unableToCreateOutput
        }
        context.interpolationQuality = .none

        for (index, frame) in acceptedFrames.enumerated() {
            guard let image = Self.decodePNG(frame.pngData) else {
                throw VerticalScrollingCaptureAssemblerError.unableToDecodeFrame
            }
            context.saveGState()
            let frameOriginY = outputHeight
                - frame.verticalOffsetPixels
                - viewportHeight
            if index > 0 {
                context.clip(to: CGRect(
                    x: 0,
                    y: frameOriginY,
                    width: viewportWidth,
                    height: frame.appendedHeightPixels
                ))
            }
            context.draw(image, in: CGRect(
                x: 0,
                y: frameOriginY,
                width: viewportWidth,
                height: viewportHeight
            ))
            context.restoreGState()
        }
        guard let image = context.makeImage() else {
            throw VerticalScrollingCaptureAssemblerError.unableToCreateOutput
        }
        let planFrames = acceptedFrames.enumerated().map { index, frame in
            ScrollingCaptureFrame(
                index: index,
                relativePath: String(format: "raw/scrolling/frame-%03d.png", index),
                verticalOffsetPixels: frame.verticalOffsetPixels,
                appendedHeightPixels: frame.appendedHeightPixels,
                overlapDifference: frame.overlapDifference
            )
        }
        return ScrollingCaptureAssembly(
            image: image,
            viewportDimensions: TraceDimensions(
                width: viewportWidth,
                height: viewportHeight
            ),
            framePNGs: acceptedFrames.map(\.pngData),
            frames: planFrames
        )
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private struct FrameSignature {
    struct Estimate {
        let deltaRows: Int?
        let bestDifference: Double
        let sameFrameDifference: Double
        let isDuplicate: Bool
    }

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(image: CGImage) throws {
        width = min(max(image.width, 1), 96)
        let proportionalHeight = Int(
            (Double(image.height) / Double(max(image.width, 1)) * Double(width)).rounded()
        )
        height = min(max(proportionalHeight, 64), 180)
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw VerticalScrollingCaptureAssemblerError.invalidFrame
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.pixels = pixels
    }

    func estimateDownwardScroll(to current: FrameSignature) -> Estimate {
        guard current.width == width, current.height == height else {
            return Estimate(
                deltaRows: nil,
                bestDifference: 1,
                sameFrameDifference: 1,
                isDuplicate: false
            )
        }
        let insetY = max(Int(Double(height) * 0.12), 2)
        let insetX = max(Int(Double(width) * 0.06), 1)
        let sameDifference = difference(
            to: current,
            deltaRows: 0,
            insetX: insetX,
            insetY: insetY
        )
        if sameDifference <= 0.018 {
            return Estimate(
                deltaRows: nil,
                bestDifference: sameDifference,
                sameFrameDifference: sameDifference,
                isDuplicate: true
            )
        }

        let minimumDelta = max(Int(Double(height) * 0.015), 2)
        let maximumDelta = min(
            Int(Double(height) * 0.82),
            height - insetY * 2 - 12
        )
        guard maximumDelta >= minimumDelta else {
            return Estimate(
                deltaRows: nil,
                bestDifference: 1,
                sameFrameDifference: sameDifference,
                isDuplicate: false
            )
        }
        var bestDelta: Int?
        var bestDifference = Double.infinity
        for delta in minimumDelta...maximumDelta {
            let candidate = difference(
                to: current,
                deltaRows: delta,
                insetX: insetX,
                insetY: insetY
            )
            if candidate < bestDifference {
                bestDifference = candidate
                bestDelta = delta
            }
        }
        return Estimate(
            deltaRows: bestDelta,
            bestDifference: bestDifference.isFinite ? bestDifference : 1,
            sameFrameDifference: sameDifference,
            isDuplicate: false
        )
    }

    private func difference(
        to current: FrameSignature,
        deltaRows: Int,
        insetX: Int,
        insetY: Int
    ) -> Double {
        let maxY = height - insetY - deltaRows
        guard maxY > insetY else { return 1 }
        var total = 0
        var count = 0
        for y in stride(from: insetY, to: maxY, by: 2) {
            let previousRow = (y + deltaRows) * width
            let currentRow = y * width
            for x in stride(from: insetX, to: width - insetX, by: 2) {
                total += abs(Int(pixels[previousRow + x]) - Int(current.pixels[currentRow + x]))
                count += 1
            }
        }
        guard count > 0 else { return 1 }
        return Double(total) / Double(count * 255)
    }
}
