import Foundation

struct LensLibraryPersistentIndex: Codable, Equatable, Sendable {
    // Version 3 guarantees every cached portable document passed the central
    // project-schema compatibility gate before its searchable fields were stored.
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var records: [LensLibraryIndexRecord]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        records: [LensLibraryIndexRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

struct LensLibraryIndexRecord: Codable, Equatable, Sendable {
    let packagePathComponents: [String]
    let manifestFingerprint: LensLibraryFileFingerprint
    let ocrFingerprint: LensLibraryFileFingerprint
    let transcriptFingerprint: LensLibraryFileFingerprint
    let insightsFingerprint: LensLibraryFileFingerprint
    let manifest: LensManifest
    let ocrText: String?
    let transcriptText: String?
    let insights: LensInsightsDocument?

    var cacheKey: String { packagePathComponents.joined(separator: "/") }
}

struct LensLibraryFileFingerprint: Codable, Equatable, Sendable {
    let exists: Bool
    let byteCount: UInt64
    let modificationTime: Double

    static let missing = Self(exists: false, byteCount: 0, modificationTime: 0)
}

struct LensLibraryPersistentIndexStore: Sendable {
    let rootDirectory: URL
    let indexURL: URL

    func entries(packageURLs: [URL]) -> [LensLibraryEntry] {
        let cachedIndex = loadIndex()
        let cachedRecords = cachedIndex?.records.reduce(into: [String: LensLibraryIndexRecord]()) {
            $0[$1.cacheKey] = $1
        } ?? [:]
        var records: [LensLibraryIndexRecord] = []
        var entries: [LensLibraryEntry] = []

        for packageURL in packageURLs {
            guard let components = relativePathComponents(for: packageURL) else { continue }
            let key = components.joined(separator: "/")
            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            let ocrURL = packageURL.appendingPathComponent("analysis/ocr.json")
            let transcriptURL = packageURL.appendingPathComponent("analysis/transcript.json")
            let insightsURL = packageURL.appendingPathComponent("analysis/insights.json")
            let manifestFingerprint = fingerprint(for: manifestURL)
            guard manifestFingerprint.exists else { continue }
            let ocrFingerprint = fingerprint(for: ocrURL)
            let transcriptFingerprint = fingerprint(for: transcriptURL)
            let insightsFingerprint = fingerprint(for: insightsURL)

            let record: LensLibraryIndexRecord
            if let cached = cachedRecords[key],
               cached.manifestFingerprint == manifestFingerprint,
               cached.ocrFingerprint == ocrFingerprint,
               cached.transcriptFingerprint == transcriptFingerprint,
               cached.insightsFingerprint == insightsFingerprint {
                record = cached
            } else {
                guard let rebuilt = rebuildRecord(
                    packagePathComponents: components,
                    manifestURL: manifestURL,
                    ocrURL: ocrURL,
                    transcriptURL: transcriptURL,
                    insightsURL: insightsURL,
                    manifestFingerprint: manifestFingerprint,
                    ocrFingerprint: ocrFingerprint,
                    transcriptFingerprint: transcriptFingerprint,
                    insightsFingerprint: insightsFingerprint
                ) else { continue }
                record = rebuilt
            }

            guard let entry = makeEntry(from: record, packageURL: packageURL) else { continue }
            records.append(record)
            entries.append(entry)
        }

        records.sort { $0.cacheKey < $1.cacheKey }
        let refreshedIndex = LensLibraryPersistentIndex(records: records)
        if refreshedIndex != cachedIndex {
            try? writeIndex(refreshedIndex)
        }
        return entries.sorted(by: Self.newestFirst)
    }

    private func rebuildRecord(
        packagePathComponents: [String],
        manifestURL: URL,
        ocrURL: URL,
        transcriptURL: URL,
        insightsURL: URL,
        manifestFingerprint: LensLibraryFileFingerprint,
        ocrFingerprint: LensLibraryFileFingerprint,
        transcriptFingerprint: LensLibraryFileFingerprint,
        insightsFingerprint: LensLibraryFileFingerprint
    ) -> LensLibraryIndexRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? decoder.decode(LensManifest.self, from: manifestData),
              (try? LensProjectSchema.manifest.validate(manifest.schemaVersion)) != nil else {
            return nil
        }
        let ocrText: String?
        if ocrFingerprint.exists,
           let data = try? Data(contentsOf: ocrURL),
           let document = try? decoder.decode(OCRDocument.self, from: data),
           (try? LensProjectSchema.ocr.validate(document.schemaVersion)) != nil {
            ocrText = document.fullText
        } else {
            ocrText = nil
        }
        let transcriptText: String?
        if transcriptFingerprint.exists,
           let data = try? Data(contentsOf: transcriptURL),
           let document = try? decoder.decode(TranscriptDocument.self, from: data),
           (try? LensProjectSchema.transcript.validate(document.schemaVersion)) != nil {
            transcriptText = document.fullText
        } else {
            transcriptText = nil
        }
        let insights: LensInsightsDocument?
        if insightsFingerprint.exists,
           let data = try? Data(contentsOf: insightsURL),
           let document = try? decoder.decode(LensInsightsDocument.self, from: data),
           (try? LensProjectSchema.insights.validate(document.schemaVersion)) != nil {
            insights = document
        } else {
            insights = nil
        }
        return LensLibraryIndexRecord(
            packagePathComponents: packagePathComponents,
            manifestFingerprint: manifestFingerprint,
            ocrFingerprint: ocrFingerprint,
            transcriptFingerprint: transcriptFingerprint,
            insightsFingerprint: insightsFingerprint,
            manifest: manifest,
            ocrText: ocrText,
            transcriptText: transcriptText,
            insights: insights
        )
    }

    private func makeEntry(
        from record: LensLibraryIndexRecord,
        packageURL: URL
    ) -> LensLibraryEntry? {
        let primaryRole: LensAsset.Role = record.manifest.kind == .screenshot
            ? .screenshot
            : .screenVideo
        guard let primaryAsset = record.manifest.assets.first(where: { $0.role == primaryRole }),
              let primaryURL = safeAssetURL(
                relativePath: primaryAsset.relativePath,
                packageURL: packageURL
              ) else {
            return nil
        }
        let preferredDisplayRoles: [LensAsset.Role] = record.manifest.kind == .screenshot
            ? [.renderedScreenshot, .thumbnail]
            : [.renderedVideo, .thumbnail]
        let displayURL = preferredDisplayRoles.lazy.compactMap { role in
            record.manifest.assets.first(where: { $0.role == role })
        }
        .compactMap {
            safeAssetURL(relativePath: $0.relativePath, packageURL: packageURL)
        }
        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? primaryURL
        return LensLibraryEntry(
            packageURL: packageURL,
            manifest: record.manifest,
            primaryAssetURL: primaryURL,
            displayAssetURL: displayURL,
            ocrText: record.ocrText,
            transcriptText: record.transcriptText,
            insights: record.insights
        )
    }

    private func safeAssetURL(relativePath: String, packageURL: URL) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let root = packageURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        let resolvedRootComponents = root.resolvingSymlinksInPath().pathComponents
        let resolvedCandidateComponents = candidate.resolvingSymlinksInPath().pathComponents
        guard resolvedCandidateComponents.count > resolvedRootComponents.count,
              Array(resolvedCandidateComponents.prefix(resolvedRootComponents.count))
                == resolvedRootComponents else {
            return nil
        }
        return candidate
    }

    private func relativePathComponents(for packageURL: URL) -> [String]? {
        let rootComponents = rootDirectory.standardizedFileURL.pathComponents
        let packageComponents = packageURL.standardizedFileURL.pathComponents
        guard packageComponents.count > rootComponents.count,
              Array(packageComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return Array(packageComponents.dropFirst(rootComponents.count))
    }

    private func fingerprint(for url: URL) -> LensLibraryFileFingerprint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return .missing
        }
        return LensLibraryFileFingerprint(
            exists: true,
            byteCount: size.uint64Value,
            modificationTime: modificationDate.timeIntervalSince1970
        )
    }

    private func loadIndex() -> LensLibraryPersistentIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let index = try? decoder.decode(LensLibraryPersistentIndex.self, from: data),
              index.schemaVersion == LensLibraryPersistentIndex.currentSchemaVersion else {
            return nil
        }
        return index
    }

    private func writeIndex(_ index: LensLibraryPersistentIndex) throws {
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private static func newestFirst(_ lhs: LensLibraryEntry, _ rhs: LensLibraryEntry) -> Bool {
        if lhs.manifest.createdAt != rhs.manifest.createdAt {
            return lhs.manifest.createdAt > rhs.manifest.createdAt
        }
        return lhs.manifest.id.uuidString > rhs.manifest.id.uuidString
    }
}
