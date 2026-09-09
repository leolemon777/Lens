import CryptoKit
import Foundation
import XCTest
@testable import LensCore

final class LensUpdateManifestTests: XCTestCase {
    func testSignedManifestVerifiesAndArtifactDigestMatches() throws {
        let signingKey = Curve25519.Signing.PrivateKey()
        let artifact = Data("Lens candidate artifact".utf8)
        let unsigned = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090501",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: LensUpdateManifestVerifier.sha256Hex(for: artifact),
            signatureBase64: "placeholder"
        )
        let signature = try signingKey.signature(for: unsigned.signedPayload)
        let manifest = LensUpdateManifest(
            channel: unsigned.channel,
            version: unsigned.version,
            build: unsigned.build,
            downloadURL: unsigned.downloadURL,
            sha256: unsigned.sha256,
            signatureBase64: signature.base64EncodedString()
        )

        XCTAssertNoThrow(try LensUpdateManifestVerifier.verify(
            manifest,
            publicKeyRawRepresentation: signingKey.publicKey.rawRepresentation
        ))
        XCTAssertTrue(LensUpdateManifestVerifier.artifactMatches(artifact, manifest: manifest))
    }

    func testManifestRejectsInsecureURLAndTampering() throws {
        let key = Curve25519.Signing.PrivateKey()
        let manifest = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090501",
            downloadURL: "http://updates.example.com/Lens.zip",
            sha256: String(repeating: "0", count: 64),
            signatureBase64: "AA=="
        )
        XCTAssertThrowsError(try LensUpdateManifestVerifier.verify(
            manifest,
            publicKeyRawRepresentation: key.publicKey.rawRepresentation
        )) { error in
            XCTAssertEqual(error as? LensUpdateManifestError, .insecureDownloadURL)
        }
    }

    func testManifestRejectsHTTPSURLWithoutHost() throws {
        let manifest = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090501",
            downloadURL: "https:/Lens.zip",
            sha256: String(repeating: "0", count: 64),
            signatureBase64: "AA=="
        )

        XCTAssertThrowsError(try LensUpdateManifestVerifier.validateShape(manifest)) { error in
            XCTAssertEqual(error as? LensUpdateManifestError, .insecureDownloadURL)
        }
    }

    func testManifestRejectsUnicodeLookalikeDigestCharacters() throws {
        let manifest = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090501",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: String(repeating: "０", count: 64),
            signatureBase64: "AA=="
        )

        XCTAssertThrowsError(try LensUpdateManifestVerifier.validateShape(manifest)) { error in
            XCTAssertEqual(error as? LensUpdateManifestError, .malformedDigest)
        }
    }

    func testManifestRejectsMalformedVersionAndBuild() throws {
        let base = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090501",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: String(repeating: "0", count: 64),
            signatureBase64: "AA=="
        )

        let malformedVersion = LensUpdateManifest(
            channel: base.channel,
            version: "0.2.beta",
            build: base.build,
            downloadURL: base.downloadURL,
            sha256: base.sha256,
            signatureBase64: base.signatureBase64
        )
        XCTAssertThrowsError(try LensUpdateManifestVerifier.validateShape(malformedVersion)) { error in
            XCTAssertEqual(error as? LensUpdateManifestError, .malformedVersion)
        }

        let malformedBuild = LensUpdateManifest(
            channel: base.channel,
            version: base.version,
            build: "2026-build",
            downloadURL: base.downloadURL,
            sha256: base.sha256,
            signatureBase64: base.signatureBase64
        )
        XCTAssertThrowsError(try LensUpdateManifestVerifier.validateShape(malformedBuild)) { error in
            XCTAssertEqual(error as? LensUpdateManifestError, .malformedBuild)
        }
    }

    func testUserInitiatedCheckerAcceptsSignedNewerBuild() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsigned = LensUpdateManifest(
            channel: "stable",
            version: "0.3.0",
            build: "2026090702",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: String(repeating: "a", count: 64),
            signatureBase64: "placeholder"
        )
        let signature = try key.signature(for: unsigned.signedPayload)
        let manifest = LensUpdateManifest(
            channel: unsigned.channel,
            version: unsigned.version,
            build: unsigned.build,
            downloadURL: unsigned.downloadURL,
            sha256: unsigned.sha256,
            signatureBase64: signature.base64EncodedString()
        )
        let data = try JSONEncoder().encode(manifest)
        let checker = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { data }
        )

        let result = await checker.check()

        XCTAssertEqual(result, .available(manifest))
    }

    func testCheckerRejectsDowngradeAndWrongChannel() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let makeManifest: (String, String) throws -> Data = { channel, build in
            let unsigned = LensUpdateManifest(
                channel: channel,
                version: "0.2.0",
                build: build,
                downloadURL: "https://updates.example.com/Lens.zip",
                sha256: String(repeating: "b", count: 64),
                signatureBase64: "placeholder"
            )
            let signature = try key.signature(for: unsigned.signedPayload)
            return try JSONEncoder().encode(LensUpdateManifest(
                channel: unsigned.channel,
                version: unsigned.version,
                build: unsigned.build,
                downloadURL: unsigned.downloadURL,
                sha256: unsigned.sha256,
                signatureBase64: signature.base64EncodedString()
            ))
        }

        let downgrade = try makeManifest("stable", "2026090501")
        let downgradeChecker = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { downgrade }
        )
        let downgradeResult = await downgradeChecker.check()
        XCTAssertEqual(downgradeResult, .failed(.notNewer))

        let wrongChannel = try makeManifest("beta", "2026090702")
        let channelChecker = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { wrongChannel }
        )
        let channelResult = await channelChecker.check()
        XCTAssertEqual(channelResult, .failed(.channelMismatch))
    }

    func testCheckerReportsSameBuildAsUpToDate() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsigned = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090601",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: String(repeating: "c", count: 64),
            signatureBase64: "placeholder"
        )
        let signature = try key.signature(for: unsigned.signedPayload)
        let manifest = LensUpdateManifest(
            channel: unsigned.channel,
            version: unsigned.version,
            build: unsigned.build,
            downloadURL: unsigned.downloadURL,
            sha256: unsigned.sha256,
            signatureBase64: signature.base64EncodedString()
        )
        let data = try JSONEncoder().encode(manifest)
        let checker = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { data }
        )

        let result = await checker.check()

        XCTAssertEqual(result, .upToDate)
    }

    func testCheckerTreatsEquivalentSemanticVersionsAsSameVersion() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsigned = LensUpdateManifest(
            channel: "stable",
            version: "0.2.0",
            build: "2026090601",
            downloadURL: "https://updates.example.com/Lens.zip",
            sha256: String(repeating: "d", count: 64),
            signatureBase64: "placeholder"
        )
        let signature = try key.signature(for: unsigned.signedPayload)
        let manifest = LensUpdateManifest(
            channel: unsigned.channel,
            version: unsigned.version,
            build: unsigned.build,
            downloadURL: unsigned.downloadURL,
            sha256: unsigned.sha256,
            signatureBase64: signature.base64EncodedString()
        )
        let data = try JSONEncoder().encode(manifest)
        let checker = LensUpdateChecker(
            currentVersion: "0.2",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { data }
        )

        let result = await checker.check()

        XCTAssertEqual(result, .upToDate)
    }

    func testCheckerKeepsOfflineAndMalformedResponsesNonDestructive() async {
        let key = Curve25519.Signing.PrivateKey()
        let offline = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { throw URLError(.notConnectedToInternet) }
        )
        let offlineResult = await offline.check()
        XCTAssertEqual(offlineResult, .failed(.transport))

        let malformed = LensUpdateChecker(
            currentVersion: "0.2.0",
            currentBuild: "2026090601",
            channel: "stable",
            publicKeyRawRepresentation: key.publicKey.rawRepresentation,
            loadManifest: { Data("not-json".utf8) }
        )
        let malformedResult = await malformed.check()
        XCTAssertEqual(malformedResult, .failed(.malformedPayload))
    }
}
