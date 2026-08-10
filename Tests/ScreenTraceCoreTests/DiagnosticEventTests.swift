import XCTest
@testable import ScreenTraceCore

final class DiagnosticEventTests: XCTestCase {
    func testEventKeepsOnlySafeAllowlistedMetadata() throws {
        let event = DiagnosticEvent(
            code: "recording.failed",
            metadata: [
                "phase": "stop",
                "count": "2",
                "projectPath": "/Users/example/secret.screentrace",
                "status": "/private/recording.mov",
                "intent": "file:///private/secret",
                "captureMode": "window\nprivate title",
                "storageLevel": "secret transcript"
            ]
        )

        XCTAssertEqual(event.code, "recording.failed")
        XCTAssertEqual(event.metadata, ["phase": "stop", "count": "2"])

        let untrustedJSON = Data(
            #"{"timestamp":0,"level":"error","code":"preview.failed","metadata":{"phase":"render","status":"secret transcript","intent":"/Users/example/private"}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: untrustedJSON)
        XCTAssertEqual(decoded.metadata, ["phase": "render"])
    }

    func testErrorMetadataDoesNotIncludeLocalizedDescription() {
        let error = NSError(
            domain: "ScreenTrace.Test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret transcript"]
        )

        XCTAssertEqual(
            DiagnosticEvent.errorMetadata(error),
            ["errorDomain": "ScreenTrace.Test", "errorCode": "42"]
        )
        XCTAssertFalse(DiagnosticEvent.errorMetadata(error).values.contains("secret transcript"))
    }
}
