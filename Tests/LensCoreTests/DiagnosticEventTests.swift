import XCTest
@testable import LensCore

final class DiagnosticEventTests: XCTestCase {
    func testEventKeepsOnlySafeAllowlistedMetadata() throws {
        let event = DiagnosticEvent(
            code: "recording.failed",
            metadata: [
                "phase": "stop",
                "count": "2",
                "durationMilliseconds": "4.125",
                "renderEncodePassCount": "2",
                "renderMilliseconds": "8.125",
                "renderPeakPhysicalFootprintBytes": "1024",
                "averageMilliseconds": "0.031",
                "maximumMilliseconds": "0.114",
                "totalMilliseconds": "2.480",
                "projectPath": "/Users/example/secret.lens",
                "status": "/private/recording.mov",
                "intent": "file:///private/secret",
                "captureMode": "window\nprivate title",
                "storageLevel": "secret transcript"
            ]
        )

        XCTAssertEqual(event.code, "recording.failed")
        XCTAssertEqual(event.metadata, [
            "averageMilliseconds": "0.031",
            "count": "2",
            "durationMilliseconds": "4.125",
            "maximumMilliseconds": "0.114",
            "phase": "stop",
            "renderEncodePassCount": "2",
            "renderMilliseconds": "8.125",
            "renderPeakPhysicalFootprintBytes": "1024",
            "totalMilliseconds": "2.480"
        ])

        let untrustedJSON = Data(
            #"{"timestamp":0,"level":"error","code":"preview.failed","metadata":{"phase":"render","status":"secret transcript","intent":"/Users/example/private"}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: untrustedJSON)
        XCTAssertEqual(decoded.metadata, ["phase": "render"])
    }

    func testErrorMetadataDoesNotIncludeLocalizedDescription() {
        let error = NSError(
            domain: "Lens.Test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret transcript"]
        )

        XCTAssertEqual(
            DiagnosticEvent.errorMetadata(error),
            ["errorDomain": "Lens.Test", "errorCode": "42"]
        )
        XCTAssertFalse(DiagnosticEvent.errorMetadata(error).values.contains("secret transcript"))
    }

    func testTaskTimingMetadataKeepsSafeCancellationReasonAndDropsPaths() {
        let event = DiagnosticEvent(
            code: "task.render.cancelled",
            metadata: [
                "taskKind": "render",
                "taskOutcome": "cancelled",
                "cancellationReason": "superseded",
                "queueMilliseconds": "120",
                "executionMilliseconds": "450",
                "projectPath": "/Users/example/private.lens"
            ]
        )

        XCTAssertEqual(event.metadata, [
            "cancellationReason": "superseded",
            "executionMilliseconds": "450",
            "queueMilliseconds": "120",
            "taskKind": "render",
            "taskOutcome": "cancelled"
        ])
    }

    func testCoreFailureLogUsesOnlySanitizedErrorMetadata() {
        let error = NSError(
            domain: "Lens.Test / private path",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "/Users/example/secret transcript"]
        )

        XCTAssertEqual(
            LensCoreLog.safeErrorMetadata(error),
            ["errorDomain": "Lens.Test___private_path", "errorCode": "42"]
        )
        XCTAssertFalse(
            LensCoreLog.safeErrorMetadata(error).values.contains("secret transcript")
        )
    }
}
