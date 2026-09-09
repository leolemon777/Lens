import Foundation
import XCTest
@testable import LensMac

final class BuildIdentityTests: XCTestCase {
    func testBuildIdentityExposesStablePresentationAndSafeDiagnostics() {
        let identity = BuildIdentity(
            version: "1.2.3",
            buildNumber: "20260812010101",
            gitCommit: "1234567890abcdef",
            sourceSnapshotSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            builtAt: Date(timeIntervalSince1970: 1_786_500_000),
            channel: .beta,
            executableURL: URL(fileURLWithPath: "/Applications/Lens.app/Contents/MacOS/Lens")
        )

        XCTAssertEqual(identity.displayVersion, "1.2.3 (20260812010101)")
        XCTAssertEqual(identity.shortCommit, "1234567890ab")
        XCTAssertTrue(identity.displayDetail.contains("Beta"))
        XCTAssertEqual(identity.diagnosticMetadata["channel"], "beta")
        XCTAssertEqual(identity.diagnosticMetadata["sourceSnapshotSHA256"], "0123456789ab")
        XCTAssertNil(identity.diagnosticMetadata["executableURL"])
    }

    func testSameBuildRequiresSameExecutableLocation() {
        let installed = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            executableURL: URL(fileURLWithPath: "/Applications/Lens.app/Contents/MacOS/Lens")
        )
        let workspace = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            executableURL: URL(fileURLWithPath: "/Volumes/ExternalSSD/Lens/Build/Lens.app/Contents/MacOS/Lens")
        )

        XCTAssertTrue(installed.isSameBuild(as: installed))
        XCTAssertFalse(installed.isSameBuild(as: workspace))
    }

    func testSameBuildRejectsDifferentSourceSnapshot() {
        let current = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            sourceSnapshotSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            executableURL: URL(fileURLWithPath: "/Applications/Lens.app/Contents/MacOS/Lens")
        )
        let stale = BuildIdentity(
            version: "0.1.0",
            buildNumber: "42",
            gitCommit: "abcdef123456",
            sourceSnapshotSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            executableURL: URL(fileURLWithPath: "/Applications/Lens.app/Contents/MacOS/Lens")
        )

        XCTAssertFalse(current.isSameBuild(as: stale))
    }

    func testConflictDetectorUsesOldestRunningInstanceDeterministically() {
        let current = BuildIdentity(
            version: "0.2.0",
            buildNumber: "20",
            gitCommit: "bbbbbbb",
            executableURL: URL(fileURLWithPath: "/current/Lens")
        )
        let older = RunningLensInstance(
            processIdentifier: 20,
            identity: BuildIdentity(
                version: "0.1.0",
                buildNumber: "10",
                gitCommit: "aaaaaaa",
                executableURL: URL(fileURLWithPath: "/old/Lens")
            )
        )
        let newerPID = RunningLensInstance(
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
            executableURL: URL(fileURLWithPath: "/current/Lens")
        )
        let running = RunningLensInstance(processIdentifier: 20, identity: current)

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
