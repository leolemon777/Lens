import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CoreWorkerLaunchConfiguration: Sendable {
    public let executableURL: URL?
    public let arguments: [String]
    public let clientName: String
    public let timeoutSeconds: TimeInterval
    public let maximumOutputBytes: Int

    public init(
        executableURL: URL?,
        arguments: [String] = [],
        clientName: String = "LensMac",
        timeoutSeconds: TimeInterval = 2,
        maximumOutputBytes: Int = CoreWorkerProtocol.maximumFrameBytes + 4
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.clientName = clientName
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public struct CoreWorkerNegotiation: Equatable, Sendable {
    public let workerVersion: String
    public let negotiatedCapabilities: [CoreWorkerCapability]

    public init(workerVersion: String, negotiatedCapabilities: [CoreWorkerCapability]) {
        self.workerVersion = workerVersion
        self.negotiatedCapabilities = Array(Set(negotiatedCapabilities)).sorted {
            $0.rawValue < $1.rawValue
        }
    }
}

public enum CoreWorkerFallbackReason: Equatable, Sendable {
    case notConfigured
    case invalidConfiguration
    case executableUnavailable
    case launchFailed
    case timedOut
    case processFailed
    case outputTooLarge
    case malformedResponse
    case incompatibleProtocol
    case mismatchedRequest
    case workerError(CoreWorkerErrorCode)
}

public enum CoreWorkerRoute: Equatable, Sendable {
    case worker(CoreWorkerNegotiation)
    case swiftFallback(CoreWorkerFallbackReason)
}

public struct CoreWorkerRuntimeAdapter: Sendable {
    public let configuration: CoreWorkerLaunchConfiguration

    public init(configuration: CoreWorkerLaunchConfiguration) {
        self.configuration = configuration
    }

    public func selectRoute(
        requestID: UUID = UUID(),
        requestedCapabilities: [CoreWorkerCapability]
    ) async -> CoreWorkerRoute {
        let configuration = self.configuration
        return await Task.detached(priority: .utility) {
            Self.performHandshake(
                configuration: configuration,
                requestID: requestID,
                requestedCapabilities: requestedCapabilities
            )
        }.value
    }

    private static func performHandshake(
        configuration: CoreWorkerLaunchConfiguration,
        requestID: UUID,
        requestedCapabilities: [CoreWorkerCapability]
    ) -> CoreWorkerRoute {
        guard let executableURL = configuration.executableURL else {
            return .swiftFallback(.notConfigured)
        }
        let clientName = configuration.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientName.isEmpty,
              clientName.utf8.count <= 128,
              configuration.timeoutSeconds.isFinite,
              configuration.timeoutSeconds > 0,
              configuration.maximumOutputBytes >= 4,
              configuration.maximumOutputBytes <= CoreWorkerProtocol.maximumFrameBytes + 4 else {
            return .swiftFallback(.invalidConfiguration)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .swiftFallback(.executableUnavailable)
        }

        let request = CoreWorkerHandshakeRequest(
            requestID: requestID,
            clientName: clientName,
            requestedCapabilities: requestedCapabilities
        )
        let frame: Data
        do {
            frame = try CoreWorkerFrameCodec.encode(request)
        } catch {
            return .swiftFallback(.invalidConfiguration)
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let termination = DispatchSemaphore(value: 0)
        let readers = DispatchGroup()
        let output = BoundedWorkerOutput(limit: configuration.maximumOutputBytes)
        let ignoredError = BoundedWorkerOutput(limit: 16_384)

        process.executableURL = executableURL
        process.arguments = configuration.arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            try? standardInput.fileHandleForWriting.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            return .swiftFallback(.launchFailed)
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(standardOutput.fileHandleForReading, into: output)
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            drain(standardError.fileHandleForReading, into: ignoredError)
            readers.leave()
        }

        do {
            try standardInput.fileHandleForWriting.write(contentsOf: frame)
            try standardInput.fileHandleForWriting.close()
        } catch {
            try? standardInput.fileHandleForWriting.close()
            terminate(process, termination: termination)
            readers.wait()
            return .swiftFallback(.launchFailed)
        }

        let deadline = DispatchTime.now() + configuration.timeoutSeconds
        guard termination.wait(timeout: deadline) == .success else {
            terminate(process, termination: termination)
            readers.wait()
            return .swiftFallback(.timedOut)
        }
        readers.wait()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .swiftFallback(.processFailed)
        }
        guard !output.exceededLimit else {
            return .swiftFallback(.outputTooLarge)
        }

        var responseBuffer = output.data
        let replies: [CoreWorkerHandshakeReply]
        do {
            replies = try CoreWorkerFrameCodec.decode(
                from: &responseBuffer,
                as: CoreWorkerHandshakeReply.self,
                maximumBytes: configuration.maximumOutputBytes - 4
            )
        } catch let error as CoreWorkerFrameError {
            if case .payloadTooLarge = error {
                return .swiftFallback(.outputTooLarge)
            }
            return .swiftFallback(.malformedResponse)
        } catch {
            return .swiftFallback(.malformedResponse)
        }
        guard responseBuffer.isEmpty, replies.count == 1, let reply = replies.first else {
            return .swiftFallback(.malformedResponse)
        }

        switch reply {
        case .response(let response):
            guard response.protocolVersion == CoreWorkerProtocol.currentVersion else {
                return .swiftFallback(.incompatibleProtocol)
            }
            guard response.requestID == requestID else {
                return .swiftFallback(.mismatchedRequest)
            }
            let workerVersion = response.workerVersion
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workerVersion.isEmpty,
                  workerVersion.utf8.count <= 128,
                  workerVersion.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else {
                return .swiftFallback(.malformedResponse)
            }
            let requested = Set(request.requestedCapabilities)
            return .worker(CoreWorkerNegotiation(
                workerVersion: workerVersion,
                negotiatedCapabilities: response.supportedCapabilities.filter(requested.contains)
            ))

        case .error(let response):
            guard response.protocolVersion == CoreWorkerProtocol.currentVersion else {
                return .swiftFallback(.incompatibleProtocol)
            }
            if let responseID = response.requestID, responseID != requestID {
                return .swiftFallback(.mismatchedRequest)
            }
            return .swiftFallback(.workerError(response.code))
        }
    }

    private static func drain(_ handle: FileHandle, into output: BoundedWorkerOutput) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                    return
                }
                output.append(chunk)
            } catch {
                return
            }
        }
    }

    private static func terminate(_ process: Process, termination: DispatchSemaphore) {
        if process.isRunning {
            process.terminate()
        }
        if termination.wait(timeout: .now() + 0.25) == .success {
            return
        }
        #if canImport(Darwin) || canImport(Glibc)
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        #endif
        _ = termination.wait(timeout: .now() + 1)
    }
}

private enum CoreWorkerHandshakeReply: Decodable {
    case response(CoreWorkerHandshakeResponse)
    case error(CoreWorkerErrorResponse)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let response = try? container.decode(CoreWorkerHandshakeResponse.self) {
            self = .response(response)
            return
        }
        if let response = try? container.decode(CoreWorkerErrorResponse.self) {
            self = .error(response)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported worker handshake reply"
        )
    }
}

private final class BoundedWorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var didExceedLimit = false

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    func append(_ chunk: Data) {
        lock.withLock {
            guard !didExceedLimit else { return }
            guard chunk.count <= limit - storage.count else {
                didExceedLimit = true
                storage.removeAll(keepingCapacity: false)
                return
            }
            storage.append(chunk)
        }
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    var data: Data {
        lock.withLock { storage }
    }
}
