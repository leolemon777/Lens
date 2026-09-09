import CryptoKit
import Foundation

public struct LensUpdateManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let channel: String
    public let version: String
    public let build: String
    public let downloadURL: String
    public let sha256: String
    public let signatureBase64: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        channel: String,
        version: String,
        build: String,
        downloadURL: String,
        sha256: String,
        signatureBase64: String
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.signatureBase64 = signatureBase64
    }

    /// Stable bytes signed by the release service. The signature itself is
    /// excluded so the same payload can be reconstructed by every platform.
    public var signedPayload: Data {
        Data([
            "lens-update-v1",
            String(schemaVersion),
            channel,
            version,
            build,
            downloadURL,
            sha256.lowercased()
        ].joined(separator: "\n").utf8)
    }
}

public enum LensUpdateManifestError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case emptyField(String)
    case invalidChannel
    case malformedVersion
    case malformedBuild
    case insecureDownloadURL
    case malformedDigest
    case malformedSignature
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "更新清单 schema \(version) 不受支持。"
        case let .emptyField(field):
            return "更新清单缺少 \(field)。"
        case .invalidChannel:
            return "更新清单 channel 无效。"
        case .malformedVersion:
            return "更新清单版本号无效。"
        case .malformedBuild:
            return "更新清单构建号无效。"
        case .insecureDownloadURL:
            return "更新下载地址必须使用 HTTPS。"
        case .malformedDigest:
            return "更新包 SHA-256 摘要无效。"
        case .malformedSignature:
            return "更新清单签名编码无效。"
        case .invalidSignature:
            return "更新清单签名校验失败。"
        }
    }
}

public enum LensUpdateManifestVerifier {
    public static func validateShape(_ manifest: LensUpdateManifest) throws {
        guard manifest.schemaVersion == LensUpdateManifest.currentSchemaVersion else {
            throw LensUpdateManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        for (field, value) in [
            ("channel", manifest.channel),
            ("version", manifest.version),
            ("build", manifest.build),
            ("downloadURL", manifest.downloadURL),
            ("sha256", manifest.sha256),
            ("signatureBase64", manifest.signatureBase64)
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LensUpdateManifestError.emptyField(field)
        }
        guard ["stable", "beta", "dev"].contains(manifest.channel) else {
            throw LensUpdateManifestError.invalidChannel
        }
        guard Self.isNumericVersion(manifest.version) else {
            throw LensUpdateManifestError.malformedVersion
        }
        guard Self.isASCIIDigits(manifest.build), Int(manifest.build) != nil else {
            throw LensUpdateManifestError.malformedBuild
        }
        guard let url = URL(string: manifest.downloadURL),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            throw LensUpdateManifestError.insecureDownloadURL
        }
        let digest = manifest.sha256.lowercased()
        guard digest.count == 64,
              digest.utf8.allSatisfy(Self.isASCIIHexDigit) else {
            throw LensUpdateManifestError.malformedDigest
        }
        guard Data(base64Encoded: manifest.signatureBase64) != nil else {
            throw LensUpdateManifestError.malformedSignature
        }
    }

    public static func verify(
        _ manifest: LensUpdateManifest,
        publicKeyRawRepresentation: Data
    ) throws {
        try validateShape(manifest)
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKeyRawRepresentation
            )
        } catch {
            throw LensUpdateManifestError.invalidSignature
        }
        guard let signature = Data(base64Encoded: manifest.signatureBase64),
              publicKey.isValidSignature(signature, for: manifest.signedPayload) else {
            throw LensUpdateManifestError.invalidSignature
        }
    }

    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func artifactMatches(_ data: Data, manifest: LensUpdateManifest) -> Bool {
        sha256Hex(for: data).caseInsensitiveCompare(manifest.sha256) == .orderedSame
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 70)
            || (byte >= 97 && byte <= 102)
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isNumericVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else { return false }
        return components.allSatisfy { component in
            let text = String(component)
            return isASCIIDigits(text) && Int(text) != nil
        }
    }
}
