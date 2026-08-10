import CoreGraphics
import XCTest
@testable import ScreenTraceMac

final class VerticalScrollingCaptureAssemblerTests: XCTestCase {
    func testFixedHeaderFramesAreDeduplicatedAndStitchedWithoutRepeatingHeader() throws {
        let assembler = VerticalScrollingCaptureAssembler()
        let first = try makeViewport(width: 240, height: 180, contentOffset: 0)
        let second = try makeViewport(width: 240, height: 180, contentOffset: 96)
        let third = try makeViewport(width: 240, height: 180, contentOffset: 210)

        XCTAssertEqual(try assembler.append(first), .first)
        guard case let .duplicate(difference) = try assembler.append(first) else {
            return XCTFail("Identical viewport should be ignored")
        }
        XCTAssertLessThan(difference, 0.01)
        guard case let .appended(firstDelta, firstDifference) = try assembler.append(second) else {
            return XCTFail("Second viewport should overlap")
        }
        guard case let .appended(secondDelta, secondDifference) = try assembler.append(third) else {
            return XCTFail("Third viewport should overlap")
        }
        XCTAssertLessThanOrEqual(abs(firstDelta - 96), 4)
        XCTAssertLessThanOrEqual(abs(secondDelta - 114), 4)
        XCTAssertLessThan(firstDifference, 0.08)
        XCTAssertLessThan(secondDifference, 0.11)

        let result = try assembler.render()
        XCTAssertEqual(result.image.width, 240)
        XCTAssertEqual(result.image.height, 180 + firstDelta + secondDelta)
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertEqual(result.framePNGs.count, 3)
        XCTAssertEqual(result.frames[1].verticalOffsetPixels, firstDelta)
        XCTAssertEqual(result.frames[2].verticalOffsetPixels, firstDelta + secondDelta)

        let pixels = try rgbaBytes(result.image)
        var fixedHeaderPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] == 250,
               pixels[index + 1] == 0,
               pixels[index + 2] == 250 {
                fixedHeaderPixels += 1
            }
        }
        XCTAssertEqual(fixedHeaderPixels, 240 * 20)
    }

    func testDimensionChangesAndOutputLimitAreHandledWithoutCorruptingAcceptedFrames() throws {
        let assembler = VerticalScrollingCaptureAssembler(
            maximumFrames: 8,
            maximumOutputPixelCount: 1_000_000,
            maximumOutputHeight: 260
        )
        let first = try makeViewport(width: 200, height: 180, contentOffset: 0)
        let second = try makeViewport(width: 200, height: 180, contentOffset: 100)
        let wrongSize = try makeViewport(width: 201, height: 180, contentOffset: 200)

        XCTAssertEqual(try assembler.append(first), .first)
        XCTAssertEqual(try assembler.append(second), .limitReached)
        XCTAssertEqual(assembler.acceptedFrameCount, 1)
        XCTAssertThrowsError(try assembler.append(wrongSize)) { error in
            XCTAssertTrue(error is VerticalScrollingCaptureAssemblerError)
        }

        let result = try assembler.render()
        XCTAssertEqual(result.image.height, 180)
        XCTAssertEqual(result.frames.count, 1)
    }

    func testSparseFlatWebCardsDoNotProduceShortFalseOffsets() throws {
        let assembler = VerticalScrollingCaptureAssembler()
        let offsets = [0, 420, 840, 1_260]
        let frames = try offsets.map {
            try makeFlatCardViewport(width: 1_200, height: 720, contentOffset: $0)
        }

        XCTAssertEqual(try assembler.append(frames[0]), .first)
        for (index, frame) in frames.dropFirst().enumerated() {
            let disposition = try assembler.append(frame)
            guard case let .appended(delta, difference) = disposition else {
                return XCTFail(
                    "Flat web card frame \(index + 1) should overlap: \(disposition)"
                )
            }
            XCTAssertLessThanOrEqual(
                abs(delta - 420),
                12,
                "Unexpected flat-card delta \(delta), score \(difference)"
            )
            XCTAssertLessThan(difference, 0.08)
        }
    }

    private func makeViewport(
        width: Int,
        height: Int,
        contentOffset: Int,
        fixedHeaderHeight: Int = 20
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if y < fixedHeaderHeight {
                    bytes[index] = 250
                    bytes[index + 1] = 0
                    bytes[index + 2] = 250
                } else {
                    let documentY = contentOffset + y - fixedHeaderHeight
                    let xBlock = x / 9
                    let yBlock = documentY / 7
                    bytes[index] = UInt8((xBlock * 31 + yBlock * 17 + 23) % 220)
                    bytes[index + 1] = UInt8((xBlock * 11 + yBlock * 43 + 47) % 220)
                    bytes[index + 2] = UInt8((xBlock * 53 + yBlock * 7 + 71) % 220)
                }
                bytes[index + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
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
            throw XCTSkip("Unable to create synthetic scrolling viewport")
        }
        return image
    }

    private func makeFlatCardViewport(
        width: Int,
        height: Int,
        contentOffset: Int,
        fixedHeaderHeight: Int = 36
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if y < fixedHeaderHeight {
                    bytes[index] = 24
                    bytes[index + 1] = 82
                    bytes[index + 2] = 66
                } else {
                    let documentY = contentOffset + y - fixedHeaderHeight
                    let card = documentY / 430
                    let withinCard = documentY % 430
                    let cardTop = withinCard < 390
                    let isBorder = withinCard < 3 || (387..<390).contains(withinCard)
                    let headingEnd = 260 + (card * 83) % 420
                    let textEnd = 560 + (card * 137) % 520
                    let isHeading = (70..<92).contains(withinCard) && (60..<headingEnd).contains(x)
                        && ((x / 13 + card * 2) % 5 != 0)
                    let isText = (145..<169).contains(withinCard) && (60..<textEnd).contains(x)
                        && ((x / 23 + card * 3) % 7 != 0)
                    let base: (UInt8, UInt8, UInt8) = card % 3 == 0
                        ? (248, 248, 246)
                        : (card % 3 == 1 ? (244, 240, 252) : (252, 244, 236))
                    let color: (UInt8, UInt8, UInt8)
                    if isBorder {
                        color = (198, 211, 204)
                    } else if isHeading {
                        color = (20, 128, 92)
                    } else if isText {
                        color = (28, 33, 31)
                    } else if cardTop {
                        color = base
                    } else {
                        color = (237, 243, 239)
                    }
                    bytes[index] = color.0
                    bytes[index + 1] = color.1
                    bytes[index + 2] = color.2
                }
                bytes[index + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
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
            throw XCTSkip("Unable to create flat web card viewport")
        }
        return image
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to inspect stitched pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
