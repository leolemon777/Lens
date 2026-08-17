import Foundation
import XCTest
@testable import ScreenTraceMac

final class BuildIdentityTests: XCTestCase {
    func testBuildIdentityExposesStablePresentationAndSafeDiagnostics() {
        let identity = BuildIdentity(
            version: "1.2.3",
            buildNumber: "20260812010101",
            gitCommit: "1234567890abcdef",
            builtAt: Date(timeIntervalSince1970: 1_786_500_000),
            channel: .beta,
            executableURL: URL(fileURLWithPath: "/Applications/ScreenTrace.app/Contents/MacOS/ScreenTrace")
        )

        XCTAssertEqual(identity.displayVersion, "1.2.3 (20260812010101)")
        XCTAssertEqual(identity.shortCommit, "1234567890ab")
        XCTAssertTrue(identity.displayDetail.contains("Beta"))
        XCTAssertEqual(identity.diagnosticMetadata["channel"], "beta")
        XCTAssertNil(identity.diagnosticMetadata["executableURL"])
    }

    func testSameBuildRequiresSameExecutableLocation() {
        let installed = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            executableURL: URL(fileURLWithPath: "/Applications/ScreenTrace.app/Contents/MacOS/ScreenTrace")
        )
        let workspace = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            executableURL: URL(fileURLWithPath: "/Volumes/ExternalSSD/ScreenTrace/Build/ScreenTrace.app/Contents/MacOS/ScreenTrace")
        )

        XCTAssertTrue(installed.isSameBuild(as: installed))
        XCTAssertFalse(installed.isSameBuild(as: workspace))
    }

    func testConflictDetectorUsesOldestRunningInstanceDeterministically() {
        let current = BuildIdentity(
            version: "0.2.0",
            buildNumber: "20",
            gitCommit: "bbbbbbb",
            executableURL: URL(fileURLWithPath: "/current/ScreenTrace")
        )
        let older = RunningScreenTraceInstance(
            processIdentifier: 20,
            identity: BuildIdentity(
                version: "0.1.0",
                buildNumber: "10",
                gitCommit: "aaaaaaa",
                executableURL: URL(fileURLWithPath: "/old/ScreenTrace")
            )
        )
        let newerPID = RunningScreenTraceInstance(
            processIdentifier: 30,
            identity: current
        )

        XCTAssertEqual(
            ApplicationInstanceConflictDetector.detect(
                current: current,
                instances: [newerPID, older]
            ),
            .differentBuild(older)
        )
    }

    func testConflictDetectorRecognizesNoConflictAndSameBuild() {
        let current = BuildIdentity(
            version: "0.2.0",
            buildNumber: "20",
            gitCommit: "bbbbbbb",
            executableURL: URL(fileURLWithPath: "/current/ScreenTrace")
        )
        let running = RunningScreenTraceInstance(processIdentifier: 20, identity: current)

        XCTAssertEqual(
            ApplicationInstanceConflictDetector.detect(current: current, instances: []),
            .none
        )
        XCTAssertEqual(
            ApplicationInstanceConflictDetector.detect(current: current, instances: [running]),
            .sameBuild(running)
        )
    }
}
