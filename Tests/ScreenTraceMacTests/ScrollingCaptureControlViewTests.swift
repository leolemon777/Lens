import AppKit
import SwiftUI
import XCTest
@testable import ScreenTraceMac

@MainActor
final class ScrollingCaptureControlViewTests: XCTestCase {
    func testControlModelExplainsCaptureStatesAndRendersGlassPanel() throws {
        let model = ScrollingCaptureControlModel()
        model.update(
            disposition: .appended(deltaPixels: 320, overlapDifference: 0.02),
            acceptedFrames: 4,
            outputHeight: 2_280
        )
        XCTAssertEqual(model.acceptedFrames, 4)
        XCTAssertEqual(model.outputHeight, 2_280)
        XCTAssertTrue(model.status.contains("自动去重"))
        model.update(
            disposition: .rejected(bestDifference: 0.3),
            acceptedFrames: 4,
            outputHeight: 2_280
        )
        XCTAssertTrue(model.status.contains("慢一点"))
        model.update(
            disposition: .stabilizing(frameDifference: 0.2),
            acceptedFrames: 4,
            outputHeight: 2_280
        )
        XCTAssertTrue(model.status.contains("动态画面"))

        let root = ScrollingCaptureControlView(model: model, onCancel: {}, onFinish: {})
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(x: 0, y: 0, width: 520, height: 104)
        hostingView.layoutSubtreeIfNeeded()
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("Unable to render scrolling capture control")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = representation.representation(using: .png, properties: [:])
        XCTAssertGreaterThanOrEqual(representation.pixelsWide, 520)
        XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 104)
        XCTAssertGreaterThan(png?.count ?? 0, 5_000)
    }

    func testSessionCanFinalizeWhileItsPeriodicCaptureTaskIsActive() async throws {
        let image = try solidImage(width: 240, height: 160)
        let controller = ScrollingCaptureSessionController()
        let completed = expectation(description: "scrolling capture completed")
        var captureCount = 0
        controller.onCompleted = { result, warning in
            XCTAssertNil(warning)
            XCTAssertEqual(result.frames.count, 1)
            XCTAssertEqual(result.image.height, 160)
            completed.fulfill()
        }
        controller.onFailed = { error in
            XCTFail("Unexpected scrolling capture failure: \(error)")
            completed.fulfill()
        }

        controller.begin {
            captureCount += 1
            return image
        }
        try await Task.sleep(for: .milliseconds(80))
        controller.finish()
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertGreaterThanOrEqual(captureCount, 2)
        XCTAssertFalse(controller.isActive)
    }

    func testSessionCallbacksRemainAvailableAcrossConsecutiveCaptures() async throws {
        let image = try solidImage(width: 240, height: 160)
        let controller = ScrollingCaptureSessionController()
        let firstCompleted = expectation(description: "first scrolling capture completed")
        let secondCompleted = expectation(description: "second scrolling capture completed")
        var completionCount = 0
        controller.onCompleted = { result, warning in
            XCTAssertNil(warning)
            XCTAssertEqual(result.frames.count, 1)
            completionCount += 1
            if completionCount == 1 {
                firstCompleted.fulfill()
            } else if completionCount == 2 {
                secondCompleted.fulfill()
            }
        }
        controller.onFailed = { error in
            XCTFail("Unexpected scrolling capture failure: \(error)")
        }

        controller.begin { image }
        try await Task.sleep(for: .milliseconds(80))
        controller.finish()
        await fulfillment(of: [firstCompleted], timeout: 2)

        controller.begin { image }
        try await Task.sleep(for: .milliseconds(80))
        controller.finish()
        await fulfillment(of: [secondCompleted], timeout: 2)

        XCTAssertEqual(completionCount, 2)
        XCTAssertFalse(controller.isActive)
    }

    func testSessionWaitsForAStableViewportBeforeAppendingScrolledContent() async throws {
        let first = try patternedImage(width: 240, height: 160, verticalOffset: 0)
        let scrolled = try patternedImage(width: 240, height: 160, verticalOffset: 72)
        let controller = ScrollingCaptureSessionController()
        let completed = expectation(description: "stable scrolling capture completed")
        var captureCount = 0
        controller.onCompleted = { result, warning in
            XCTAssertNil(warning)
            XCTAssertEqual(result.frames.count, 2)
            XCTAssertGreaterThan(result.image.height, 160)
            completed.fulfill()
        }

        controller.begin {
            captureCount += 1
            return captureCount == 1 ? first : scrolled
        }
        try await Task.sleep(for: .milliseconds(1_180))
        controller.finish()
        await fulfillment(of: [completed], timeout: 2)
    }

    func testSessionDoesNotAppendContinuouslyMovingAnimationFrames() async throws {
        let frames = try (0..<5).map {
            try patternedImage(width: 240, height: 160, verticalOffset: $0 * 18)
        }
        let controller = ScrollingCaptureSessionController()
        let completed = expectation(description: "animated capture completed")
        var captureCount = 0
        controller.onCompleted = { result, warning in
            XCTAssertNil(warning)
            XCTAssertEqual(result.frames.count, 1)
            XCTAssertEqual(result.image.height, 160)
            completed.fulfill()
        }

        controller.begin {
            defer { captureCount += 1 }
            return frames[captureCount % frames.count]
        }
        try await Task.sleep(for: .milliseconds(1_180))
        controller.finish()
        await fulfillment(of: [completed], timeout: 2)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create scrolling session image")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create scrolling session image")
        }
        return image
    }

    private func patternedImage(
        width: Int,
        height: Int,
        verticalOffset: Int
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let documentY = y + verticalOffset
                let index = (y * width + x) * 4
                bytes[index] = UInt8((x * 13 + documentY * 7) % 251)
                bytes[index + 1] = UInt8((x * 3 + documentY * 17) % 241)
                bytes[index + 2] = UInt8((x * 19 + documentY * 5) % 239)
                bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw XCTSkip("Unable to create patterned scrolling image")
        }
        return image
    }
}
