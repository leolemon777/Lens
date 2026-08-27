import Foundation
import XCTest
@testable import LensCore

final class CoreWorkerProtocolTests: XCTestCase {
    func testHandshakeRoundTripDeduplicatesCapabilitiesAndCorrelatesResponse() throws {
        let requestID = UUID(uuidString: "4AA56F49-AF0A-4A5B-89F6-45D7FA0455E1")!
        let request = CoreWorkerHandshakeRequest(
            requestID: requestID,
            clientName: "LensMac",
            requestedCapabilities: [
                .captionPlanning,
                .projectSchema,
                .captionPlanning
            ]
        )

        var buffer = try CoreWorkerFrameCodec.encode(request)
        let decoded = try CoreWorkerFrameCodec.decode(
            from: &buffer,
            as: CoreWorkerHandshakeRequest.self
        )

        XCTAssertEqual(decoded, [request])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(request.requestedCapabilities, [.captionPlanning, .projectSchema])

        let response = CoreWorkerHandshakeResponse(
            requestID: requestID,
            workerVersion: "0.1.0",
            supportedCapabilities: [.projectSchema]
        )
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.protocolVersion, CoreWorkerProtocol.currentVersion)
    }

    func testDecoderPreservesPartialFrameAndConsumesMultipleCompleteFrames() throws {
        let first = CoreWorkerErrorResponse(
            requestID: nil,
            code: .workerUnavailable
        )
        let second = CoreWorkerErrorResponse(
            requestID: UUID(),
            code: .unsupportedCapability
        )
        let firstFrame = try CoreWorkerFrameCodec.encode(first)
        let secondFrame = try CoreWorkerFrameCodec.encode(second)
        let splitIndex = secondFrame.count / 2
        var buffer = firstFrame + secondFrame.prefix(splitIndex)

        XCTAssertEqual(
            try CoreWorkerFrameCodec.decode(from: &buffer, as: CoreWorkerErrorResponse.self),
            [first]
        )
        XCTAssertEqual(buffer, secondFrame.prefix(splitIndex))

        buffer.append(secondFrame.suffix(from: splitIndex))
        XCTAssertEqual(
            try CoreWorkerFrameCodec.decode(from: &buffer, as: CoreWorkerErrorResponse.self),
            [second]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCodecRejectsOversizedAndMalformedFramesBeforeDispatch() throws {
        let request = CoreWorkerHandshakeRequest(
            clientName: String(repeating: "x", count: 200),
            requestedCapabilities: [.projectSchema]
        )
        XCTAssertThrowsError(
            try CoreWorkerFrameCodec.encode(request, maximumBytes: 32)
        ) { error in
            guard case .payloadTooLarge(let actual, let maximum) = error as? CoreWorkerFrameError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 32)
        }

        var oversizedHeader = Data([0x00, 0x10, 0x00, 0x01])
        XCTAssertThrowsError(
            try CoreWorkerFrameCodec.decode(
                from: &oversizedHeader,
                as: CoreWorkerHandshakeRequest.self,
                maximumBytes: 1_024
            )
        )
        XCTAssertEqual(oversizedHeader, Data([0x00, 0x10, 0x00, 0x01]))

        var malformed = Data([0x00, 0x00, 0x00, 0x02]) + Data("{}".utf8)
        XCTAssertThrowsError(
            try CoreWorkerFrameCodec.decode(
                from: &malformed,
                as: CoreWorkerHandshakeRequest.self
            )
        ) { error in
            XCTAssertEqual(error as? CoreWorkerFrameError, .malformedPayload)
        }
    }
}
