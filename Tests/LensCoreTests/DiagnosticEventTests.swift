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
}
