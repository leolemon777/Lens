import Foundation

public enum LensUpdateCheckFailure: Equatable, Sendable {
    case transport
    case malformedPayload
    case manifest(LensUpdateManifestError)
    case channelMismatch
    case notNewer
}

public enum LensUpdateCheckResult: Equatable, Sendable {
    case available(LensUpdateManifest)
    case upToDate
    case failed(LensUpdateCheckFailure)
}

/// A user-initiated update check boundary. Networking and presentation stay
/// injected so offline behavior, downgrade protection, and signature failures
/// can be verified without contacting a release host or touching the install.
public struct LensUpdateChecker: Sendable {
    public typealias ManifestLoader = @Sendable () async throws -> Data

    private let currentVersion: String
    private let currentBuild: String
    private let channel: String
    private let publicKeyRawRepresentation: Data
    private let loadManifest: ManifestLoader

    public init(
        currentVersion: String,
        currentBuild: String,
        channel: String,
        publicKeyRawRepresentation: Data,
        loadManifest: @escaping ManifestLoader
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.channel = channel
        self.publicKeyRawRepresentation = publicKeyRawRepresentation
        self.loadManifest = loadManifest
    }

    public func check() async -> LensUpdateCheckResult {
        let data: Data
        do {
            data = try await loadManifest()
        } catch {
            return .failed(.transport)
        }

        let manifest: LensUpdateManifest
        do {
            manifest = try JSONDecoder().decode(LensUpdateManifest.self, from: data)
        } catch {
            return .failed(.malformedPayload)
        }

        do {
            try LensUpdateManifestVerifier.verify(
                manifest,
                publicKeyRawRepresentation: publicKeyRawRepresentation
            )
        } catch let error as LensUpdateManifestError {
            return .failed(.manifest(error))
        } catch {
            return .failed(.manifest(.invalidSignature))
        }

        guard manifest.channel == channel else {
            return .failed(.channelMismatch)
        }
        switch comparison(for: manifest) {
        case .newer:
            return .available(manifest)
        case .same:
            return .upToDate
        case .older:
            return .failed(.notNewer)
        }
    }

    private enum VersionComparison {
        case newer
        case same
        case older
    }

    private func comparison(for manifest: LensUpdateManifest) -> VersionComparison {
        guard let candidateVersion = SemanticVersion(manifest.version),
              let installedVersion = SemanticVersion(currentVersion) else {
            return .older
        }
        if candidateVersion > installedVersion { return .newer }
        if candidateVersion < installedVersion { return .older }

        guard let candidateBuild = Int(manifest.build),
              let installedBuild = Int(currentBuild) else {
            return .older
        }
        if candidateBuild > installedBuild { return .newer }
        if candidateBuild == installedBuild { return .same }
        return .older
    }
}

private struct SemanticVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count),
              pieces.allSatisfy({
                  guard let component = Int($0) else { return false }
                  return !$0.isEmpty && component >= 0
              }) else {
            return nil
        }
        components = pieces.map { Int($0)! }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
