import Foundation

public enum CoreWorkerProtocol {
    public static let currentVersion = 1
    public static let maximumFrameBytes = 1_048_576
}

public enum CoreWorkerCapability: String, Codable, CaseIterable, Sendable {
    case projectSchema
    case autoCameraPlanning
    case captionPlanning
    case localOrganization
}

public struct CoreWorkerHandshakeRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let clientName: String
    public let requestedCapabilities: [CoreWorkerCapability]

    public init(
        protocolVersion: Int = CoreWorkerProtocol.currentVersion,
        requestID: UUID = UUID(),
        clientName: String,
        requestedCapabilities: [CoreWorkerCapability]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.clientName = clientName
        self.requestedCapabilities = Array(Set(requestedCapabilities)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public struct CoreWorkerHandshakeResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let workerVersion: String
    public let supportedCapabilities: [CoreWorkerCapability]

    public init(
        protocolVersion: Int = CoreWorkerProtocol.currentVersion,
        requestID: UUID,
        workerVersion: String,
        supportedCapabilities: [CoreWorkerCapability]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.workerVersion = workerVersion
        self.supportedCapabilities = Array(Set(supportedCapabilities)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public enum CoreWorkerErrorCode: String, Codable, Equatable, Sendable {
    case incompatibleProtocol
    case malformedFrame
    case unsupportedCapability
    case workerUnavailable
    case internalFailure
}

public struct CoreWorkerErrorResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID?
    public let code: CoreWorkerErrorCode

    public init(
        protocolVersion: Int = CoreWorkerProtocol.currentVersion,
        requestID: UUID?,
        code: CoreWorkerErrorCode
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.code = code
    }
}

public enum CoreWorkerFrameError: Error, Equatable, Sendable {
    case payloadTooLarge(actual: Int, maximum: Int)
    case malformedPayload
}

public enum CoreWorkerFrameCodec {
    public static func encode<Value: Encodable>(
        _ value: Value,
        maximumBytes: Int = CoreWorkerProtocol.maximumFrameBytes
    ) throws -> Data {
        let maximumBytes = max(maximumBytes, 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do {
            payload = try encoder.encode(value)
        } catch {
            throw CoreWorkerFrameError.malformedPayload
        }
        guard payload.count <= maximumBytes else {
            throw CoreWorkerFrameError.payloadTooLarge(
                actual: payload.count,
                maximum: maximumBytes
            )
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func decode<Value: Decodable>(
        from buffer: inout Data,
        as type: Value.Type,
        maximumBytes: Int = CoreWorkerProtocol.maximumFrameBytes
    ) throws -> [Value] {
        let maximumBytes = max(maximumBytes, 0)
        var values: [Value] = []
        let decoder = JSONDecoder()

        while buffer.count >= 4 {
            let payloadLength = buffer.prefix(4).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard payloadLength <= maximumBytes else {
                throw CoreWorkerFrameError.payloadTooLarge(
                    actual: payloadLength,
                    maximum: maximumBytes
                )
            }
            let frameLength = 4 + payloadLength
            guard buffer.count >= frameLength else { break }
            let frameStart = buffer.startIndex
            let payloadStart = buffer.index(frameStart, offsetBy: 4)
            let frameEnd = buffer.index(frameStart, offsetBy: frameLength)
            let payload = buffer.subdata(in: payloadStart..<frameEnd)
            do {
                values.append(try decoder.decode(Value.self, from: payload))
            } catch {
                throw CoreWorkerFrameError.malformedPayload
            }
            buffer.removeSubrange(frameStart..<frameEnd)
        }
        return values
    }
}
