import CoreGraphics
import Foundation
import ImageIO
import ScreenTraceCore

enum ScrollingFrameAppendDisposition: Equatable {
    case first
    case appended(deltaPixels: Int, overlapDifference: Double)
    case duplicate(overlapDifference: Double)
    case stabilizing(frameDifference: Double)
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
        // Several equally good offsets mean the real scroll distance is unknown.
        // Another frame arrives in about half a second; waiting for an
        // unambiguous one is far cheaper than stitching a duplicated screenful.
        guard !estimate.isAmbiguous else {
            return .stabilizing(frameDifference: estimate.bestDifference)
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

struct FrameSignature {
    static let stableDifferenceThreshold = 0.018

    struct Estimate {
        let deltaRows: Int?
        let bestDifference: Double
        let sameFrameDifference: Double
        let isDuplicate: Bool
        /// The best score achievable at an offset far away from the winner.
        /// Periodic page content (tables, card lists, monospaced code) produces
        /// several near-equal minima; without this the first one silently wins.
        let runnerUpDifference: Double

        var isAmbiguous: Bool {
            guard runnerUpDifference.isFinite else { return false }
            // Periodic content can produce several exact minima (both scores 0).
            // A strict `>` would let the first one win; Lowe's test rejects a
            // match that is not significantly better than a distant runner-up.
            return bestDifference >= runnerUpDifference * 0.75
        }
    }

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(image: CGImage) throws {
        // A wider signature keeps text, card borders, and other sparse page details
        // measurable. At 96 px, large flat web layouts can make a short false
        // offset score better than the real scroll distance.
        width = min(max(image.width, 1), 256)
        let proportionalHeight = Int(
            (Double(image.height) / Double(max(image.width, 1)) * Double(width)).rounded()
        )
        height = min(max(proportionalHeight, 96), 240)
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
                isDuplicate: false,
                runnerUpDifference: .infinity
            )
        }
        // Keep enough of a narrow overlap to support larger wheel/trackpad steps.
        // Six percent still excludes ordinary browser sticky headers, while a
        // twelve-percent inset made scrolls above roughly two-thirds of a viewport
        // mathematically impossible to match.
        let insetY = max(Int(Double(height) * 0.06), 2)
        let insetX = max(Int(Double(width) * 0.06), 1)
        let sameDifference = sameFrameDifference(to: current)
        if sameDifference <= Self.stableDifferenceThreshold {
            return Estimate(
                deltaRows: nil,
                bestDifference: sameDifference,
                sameFrameDifference: sameDifference,
                isDuplicate: true,
                runnerUpDifference: .infinity
            )
        }

        let minimumDelta = max(Int(Double(height) * 0.015), 2)
        let maximumDelta = min(
            Int(Double(height) * 0.82),
            height - insetY * 2 - 8
        )
        guard maximumDelta >= minimumDelta else {
            return Estimate(
                deltaRows: nil,
                bestDifference: 1,
                sameFrameDifference: sameDifference,
                isDuplicate: false,
                runnerUpDifference: .infinity
            )
        }
        var scores = [Double](repeating: .infinity, count: maximumDelta - minimumDelta + 1)
        var bestDelta: Int?
        var bestDifference = Double.infinity
        for delta in minimumDelta...maximumDelta {
            let candidate = difference(
                to: current,
                deltaRows: delta,
                insetX: insetX,
                insetY: insetY
            )
            scores[delta - minimumDelta] = candidate
            if candidate < bestDifference {
                bestDifference = candidate
                bestDelta = delta
            }
        }
        // The runner-up must come from a genuinely different offset, not from
        // the shoulder of the same minimum, so ignore everything adjacent to the
        // winner. Rows near a real match always score well by continuity.
        var runnerUpDifference = Double.infinity
        if let bestDelta {
            let exclusion = max(Int(Double(height) * 0.02), 6)
            for delta in minimumDelta...maximumDelta where abs(delta - bestDelta) > exclusion {
                runnerUpDifference = min(runnerUpDifference, scores[delta - minimumDelta])
            }
        }
        return Estimate(
            deltaRows: bestDelta,
            bestDifference: bestDifference.isFinite ? bestDifference : 1,
            sameFrameDifference: sameDifference,
            isDuplicate: false,
            runnerUpDifference: runnerUpDifference
        )
    }

    func sameFrameDifference(to current: FrameSignature) -> Double {
        guard current.width == width, current.height == height else { return 1 }
        return difference(
            to: current,
            deltaRows: 0,
            insetX: max(Int(Double(width) * 0.06), 1),
            insetY: max(Int(Double(height) * 0.06), 2)
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
        var weightedDifference = 0.0
        var totalWeight = 0.0
        var fallbackDifference = 0
        var fallbackCount = 0
        for y in stride(from: insetY, to: maxY, by: 2) {
            let previousRow = (y + deltaRows) * width
            let currentRow = y * width
            for x in stride(from: insetX, to: width - insetX, by: 2) {
                let previousIndex = previousRow + x
                let currentIndex = currentRow + x
                let intensityDifference = abs(
                    Int(pixels[previousIndex]) - Int(current.pixels[currentIndex])
                )
                fallbackDifference += intensityDifference
                fallbackCount += 1

                let previousGradient = gradientMagnitude(at: previousIndex)
                let currentGradient = current.gradientMagnitude(at: currentIndex)
                let information = max(previousGradient, currentGradient)
                guard information >= 8 else { continue }

                // Sparse edges carry the scroll signal in otherwise uniform cards.
                // Give stronger text/border pixels more influence while keeping the
                // score normalized to the same 0...1 range as before.
                let weight = 1.0 + min(Double(information) / 32.0, 5.0)
                weightedDifference += Double(intensityDifference) * weight
                totalWeight += weight
            }
        }
        if totalWeight >= 12 {
            return weightedDifference / (totalWeight * 255)
        }
        guard fallbackCount > 0 else { return 1 }
        return Double(fallbackDifference) / Double(fallbackCount * 255)
    }

    private func gradientMagnitude(at index: Int) -> Int {
        let x = index % width
        let y = index / width
        guard x > 0, x + 1 < width, y > 0, y + 1 < height else { return 0 }
        let horizontal = abs(Int(pixels[index + 1]) - Int(pixels[index - 1]))
        let vertical = abs(Int(pixels[index + width]) - Int(pixels[index - width]))
        return max(horizontal, vertical)
    }
}
