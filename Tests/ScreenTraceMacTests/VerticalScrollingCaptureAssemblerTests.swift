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
