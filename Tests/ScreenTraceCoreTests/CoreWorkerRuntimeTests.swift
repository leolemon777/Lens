import Foundation
import XCTest
@testable import ScreenTraceCore

final class CoreWorkerRuntimeTests: XCTestCase {
    func testSuccessfulHandshakeCorrelatesRequestAndNegotiatesIntersection() async throws {
        let requestID = UUID(uuidString: "2B533C88-C771-4689-AEE7-E52049798661")!
        let response = CoreWorkerHandshakeResponse(
            requestID: requestID,
            workerVersion: "0.1.0",
            supportedCapabilities: [.projectSchema, .captionPlanning, .localOrganization]
        )
        let script = try makeWorkerScript(output: CoreWorkerFrameCodec.encode(response))
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let adapter = CoreWorkerRuntimeAdapter(configuration: CoreWorkerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            timeoutSeconds: 1
        ))

        let route = await adapter.selectRoute(
            requestID: requestID,
            requestedCapabilities: [.captionPlanning, .projectSchema]
        )

        XCTAssertEqual(route, .worker(CoreWorkerNegotiation(
            workerVersion: "0.1.0",
            negotiatedCapabilities: [.captionPlanning, .projectSchema]
        )))
    }

    func testMismatchedAndIncompatibleResponsesFallBackWithoutDispatch() async throws {
        let requestID = UUID(uuidString: "9D5952D4-1891-463D-B8E8-9A83995951A4")!
        let mismatched = CoreWorkerHandshakeResponse(
            requestID: UUID(),
            workerVersion: "0.1.0",
            supportedCapabilities: [.projectSchema]
        )
        let mismatchedScript = try makeWorkerScript(
            output: CoreWorkerFrameCodec.encode(mismatched)
        )
        defer {
            try? FileManager.default.removeItem(at: mismatchedScript.deletingLastPathComponent())
        }
        let mismatchAdapter = adapter(script: mismatchedScript)
        let mismatchRoute = await mismatchAdapter.selectRoute(
            requestID: requestID,
            requestedCapabilities: [.projectSchema]
        )
        XCTAssertEqual(mismatchRoute, .swiftFallback(.mismatchedRequest))

        let incompatible = CoreWorkerHandshakeResponse(
            protocolVersion: CoreWorkerProtocol.currentVersion + 1,
            requestID: requestID,
            workerVersion: "0.2.0",
            supportedCapabilities: [.projectSchema]
        )
        let incompatibleScript = try makeWorkerScript(
            output: CoreWorkerFrameCodec.encode(incompatible)
        )
        defer {
            try? FileManager.default.removeItem(at: incompatibleScript.deletingLastPathComponent())
        }
        let incompatibleAdapter = adapter(script: incompatibleScript)
        let incompatibleRoute = await incompatibleAdapter.selectRoute(
            requestID: requestID,
            requestedCapabilities: [.projectSchema]
        )
        XCTAssertEqual(incompatibleRoute, .swiftFallback(.incompatibleProtocol))
    }

    func testWorkerErrorAndNonzeroExitBecomeStableFallbackReasons() async throws {
        let requestID = UUID(uuidString: "B57FB565-9EAB-413E-B30D-FEFADDC4DA1E")!
        let response = CoreWorkerErrorResponse(
            requestID: requestID,
            code: .unsupportedCapability
        )
        let errorScript = try makeWorkerScript(output: CoreWorkerFrameCodec.encode(response))
        defer { try? FileManager.default.removeItem(at: errorScript.deletingLastPathComponent()) }
        let errorRoute = await adapter(script: errorScript).selectRoute(
            requestID: requestID,
            requestedCapabilities: [.captionPlanning]
        )
        XCTAssertEqual(errorRoute, .swiftFallback(.workerError(.unsupportedCapability)))

        let crashScript = try makeWorkerScript(output: Data(), exitStatus: 7)
        defer { try? FileManager.default.removeItem(at: crashScript.deletingLastPathComponent()) }
        let crashRoute = await adapter(script: crashScript).selectRoute(
            requestID: requestID,
            requestedCapabilities: [.captionPlanning]
        )
        XCTAssertEqual(crashRoute, .swiftFallback(.processFailed))
    }

    func testTimeoutAndOversizedOutputCannotBlockOrReachWorkerRoute() async throws {
        let timeoutScript = try makeWorkerScript(output: Data(), hangs: true)
        defer { try? FileManager.default.removeItem(at: timeoutScript.deletingLastPathComponent()) }
        let timeoutAdapter = CoreWorkerRuntimeAdapter(configuration: CoreWorkerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [timeoutScript.path],
            timeoutSeconds: 0.05
        ))
        let timeoutRoute = await timeoutAdapter.selectRoute(requestedCapabilities: [.projectSchema])
        XCTAssertEqual(timeoutRoute, .swiftFallback(.timedOut))

        let oversizedScript = try makeWorkerScript(output: Data(repeating: 0x41, count: 65))
        defer {
            try? FileManager.default.removeItem(at: oversizedScript.deletingLastPathComponent())
        }
        let oversizedAdapter = CoreWorkerRuntimeAdapter(configuration: CoreWorkerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [oversizedScript.path],
            timeoutSeconds: 1,
            maximumOutputBytes: 64
        ))
        let oversizedRoute = await oversizedAdapter.selectRoute(
            requestedCapabilities: [.projectSchema]
        )
        XCTAssertEqual(oversizedRoute, .swiftFallback(.outputTooLarge))
    }

    func testMissingInvalidAndMalformedWorkersUseSwiftFallback() async throws {
        let unconfiguredRoute = await CoreWorkerRuntimeAdapter(
            configuration: CoreWorkerLaunchConfiguration(executableURL: nil)
        ).selectRoute(requestedCapabilities: [.projectSchema])
        XCTAssertEqual(unconfiguredRoute, .swiftFallback(.notConfigured))

        let unavailableRoute = await CoreWorkerRuntimeAdapter(
            configuration: CoreWorkerLaunchConfiguration(
                executableURL: URL(fileURLWithPath: "/does/not/exist")
            )
        ).selectRoute(requestedCapabilities: [.projectSchema])
        XCTAssertEqual(unavailableRoute, .swiftFallback(.executableUnavailable))

        let invalidExecutable = try makeInvalidExecutable()
        defer {
            try? FileManager.default.removeItem(at: invalidExecutable.deletingLastPathComponent())
        }
        let launchFailureRoute = await CoreWorkerRuntimeAdapter(
            configuration: CoreWorkerLaunchConfiguration(
                executableURL: invalidExecutable,
                timeoutSeconds: 1
            )
        ).selectRoute(requestedCapabilities: [.projectSchema])
        XCTAssertEqual(launchFailureRoute, .swiftFallback(.launchFailed))

        let invalidRoute = await CoreWorkerRuntimeAdapter(
            configuration: CoreWorkerLaunchConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                timeoutSeconds: 0
            )
        ).selectRoute(requestedCapabilities: [.projectSchema])
        XCTAssertEqual(invalidRoute, .swiftFallback(.invalidConfiguration))

        let malformed = Data([0, 0, 0, 2]) + Data("{}".utf8)
        let malformedScript = try makeWorkerScript(output: malformed)
        defer {
            try? FileManager.default.removeItem(at: malformedScript.deletingLastPathComponent())
        }
        let malformedRoute = await adapter(script: malformedScript).selectRoute(
            requestedCapabilities: [.projectSchema]
        )
        XCTAssertEqual(malformedRoute, .swiftFallback(.malformedResponse))
    }

    private func adapter(script: URL) -> CoreWorkerRuntimeAdapter {
        CoreWorkerRuntimeAdapter(configuration: CoreWorkerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            timeoutSeconds: 1
        ))
    }

    private func makeWorkerScript(
        output: Data,
        exitStatus: Int32 = 0,
        hangs: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenTraceWorkerTest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("worker.sh")
        var contents = "#!/bin/sh\n/bin/cat >/dev/null\n"
        if hangs {
            contents += "while :; do :; done\n"
        } else if !output.isEmpty {
            contents += "/usr/bin/printf '%s' '\(output.base64EncodedString())' | /usr/bin/base64 -D\n"
        }
        contents += "exit \(exitStatus)\n"
        try Data(contents.utf8).write(to: script, options: .atomic)
        return script
    }

    private func makeInvalidExecutable() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenTraceInvalidWorker-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("invalid-worker")
        try Data("not an executable".utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        return executable
    }
}
