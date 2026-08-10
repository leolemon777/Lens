import Foundation
import XCTest
@testable import ScreenTraceCore

final class CoreWorkerGoldenFixtureTests: XCTestCase {
    private let requestID = UUID(uuidString: "4AA56F49-AF0A-4A5B-89F6-45D7FA0455E1")!

    func testLanguageNeutralProtocolV1FramesRemainByteExact() throws {
        let fixture = try loadFixture()

        XCTAssertEqual(fixture.schemaVersion, CoreWorkerProtocol.currentVersion)
        XCTAssertEqual(fixture.transport, "uint32-be-length + utf8-json")
        XCTAssertEqual(Set(fixture.cases.map(\.name)), [
            "handshake-request",
            "handshake-response",
            "worker-error"
        ])

        for goldenCase in fixture.cases {
            let frame = try encodedFrame(named: goldenCase.name)
            XCTAssertEqual(frame.hexadecimalString, goldenCase.frameHex, goldenCase.name)
            XCTAssertEqual(
                String(data: frame.dropFirst(4), encoding: .utf8),
                goldenCase.payloadJSON,
                goldenCase.name
            )
            try assertDecodes(frame: frame, named: goldenCase.name)
        }
    }

    private func encodedFrame(named name: String) throws -> Data {
        switch name {
        case "handshake-request":
            return try CoreWorkerFrameCodec.encode(CoreWorkerHandshakeRequest(
                requestID: requestID,
                clientName: "ScreenTraceMac",
                requestedCapabilities: [.projectSchema, .captionPlanning]
            ))
        case "handshake-response":
            return try CoreWorkerFrameCodec.encode(CoreWorkerHandshakeResponse(
                requestID: requestID,
                workerVersion: "0.1.0",
                supportedCapabilities: [.projectSchema, .captionPlanning]
            ))
        case "worker-error":
            return try CoreWorkerFrameCodec.encode(CoreWorkerErrorResponse(
                requestID: nil,
                code: .workerUnavailable
            ))
        default:
            throw FixtureError.unknownCase(name)
        }
    }

    private func assertDecodes(frame: Data, named name: String) throws {
        var buffer = frame
        switch name {
        case "handshake-request":
            let values = try CoreWorkerFrameCodec.decode(
                from: &buffer,
                as: CoreWorkerHandshakeRequest.self
            )
            XCTAssertEqual(values.first?.requestID, requestID)
        case "handshake-response":
            let values = try CoreWorkerFrameCodec.decode(
                from: &buffer,
                as: CoreWorkerHandshakeResponse.self
            )
            XCTAssertEqual(values.first?.requestID, requestID)
        case "worker-error":
            let values = try CoreWorkerFrameCodec.decode(
                from: &buffer,
                as: CoreWorkerErrorResponse.self
            )
            XCTAssertEqual(values.first?.code, .workerUnavailable)
        default:
            throw FixtureError.unknownCase(name)
        }
        XCTAssertTrue(buffer.isEmpty, name)
    }

    private func loadFixture() throws -> GoldenFixture {
        guard let resources = Bundle.module.resourceURL else {
            throw FixtureError.missingResource
        }
        let url = resources
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("core-worker-protocol-v1-golden.json")
        return try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
    }
}

private struct GoldenFixture: Decodable {
    let schemaVersion: Int
    let transport: String
    let cases: [GoldenCase]
}

private struct GoldenCase: Decodable {
    let name: String
    let payloadJSON: String
    let frameHex: String
}

private enum FixtureError: Error {
    case missingResource
    case unknownCase(String)
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
