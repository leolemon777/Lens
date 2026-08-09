import Foundation

public enum TraceProjectStoreError: LocalizedError, Equatable {
    case invalidDimensions
    case packageAlreadyExists
    case missingRawRecording
    case emptyRawRecording
    case missingRenderedVideo
    case incompatibleTraceKind

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "截图尺寸无效。"
        case .packageAlreadyExists:
            return "项目包已存在，无法覆盖。"
        case .missingRawRecording:
            return "原始录屏文件不存在。"
        case .emptyRawRecording:
            return "原始录屏文件为空。"
        case .missingRenderedVideo:
            return "自动成片文件不存在。"
        case .incompatibleTraceKind:
            return "项目类型不支持这项分析结果。"
        }
    }
}

public struct TraceProjectStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = Self.canonicalURLAllowingMissingComponents(rootDirectory)
    }

    public static var defaultRootDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("ScreenTrace", isDirectory: true)
    }

    public func saveScreenshot(
        pngData: Data,
        width: Int,
        height: Int,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> SavedTrace {
        guard width > 0, height > 0 else {
            throw TraceProjectStoreError.invalidDimensions
        }

        let packageURL = uniquePackageURL(createdAt: createdAt, id: id)
        guard !FileManager.default.fileExists(atPath: packageURL.path) else {
            throw TraceProjectStoreError.packageAlreadyExists
        }

        let rawDirectory = packageURL.appendingPathComponent("raw", isDirectory: true)
        let eventsDirectory = packageURL.appendingPathComponent("events", isDirectory: true)
        let analysisDirectory = packageURL.appendingPathComponent("analysis", isDirectory: true)
        let editsDirectory = packageURL.appendingPathComponent("edits", isDirectory: true)
        let previewsDirectory = packageURL.appendingPathComponent("previews", isDirectory: true)
        let rawAssetURL = rawDirectory.appendingPathComponent("screenshot.png")

        do {
            try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: analysisDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: editsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
            try pngData.write(to: rawAssetURL, options: .atomic)

            let manifest = TraceManifest(
                id: id,
                kind: .screenshot,
                createdAt: createdAt,
                title: "截图 \(Self.displayTimestamp.string(from: createdAt))",
                dimensions: TraceDimensions(width: width, height: height),
                assets: [TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: packageURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            return SavedTrace(packageURL: packageURL, rawAssetURL: rawAssetURL, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    public func loadManifest(from packageURL: URL) throws -> TraceManifest {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TraceManifest.self, from: data)
    }

    public func loadAutoEditPlan(from packageURL: URL) throws -> AutoEditPlan {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("edits/edit-plan.json"))
        return try JSONDecoder().decode(AutoEditPlan.self, from: data)
    }

    public func attachOCR(
        _ document: OCRDocument,
        to savedTrace: SavedTrace
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: savedTrace.packageURL)
        guard manifest.kind == .screenshot else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }

        let relativePath = "analysis/ocr.json"
        let outputURL = savedTrace.packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: outputURL, options: .atomic)

        if !manifest.assets.contains(where: { $0.role == .ocr }) {
            manifest.assets.append(TraceAsset(role: .ocr, relativePath: relativePath))
        }
        try writeManifest(manifest, to: savedTrace.packageURL)
        return SavedTrace(
            packageURL: savedTrace.packageURL,
            rawAssetURL: savedTrace.rawAssetURL,
            manifest: manifest
        )
    }

    public func loadOCR(from packageURL: URL) throws -> OCRDocument {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("analysis/ocr.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OCRDocument.self, from: data)
    }

    public func beginRecording(
        width: Int,
        height: Int,
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> RecordingTraceSession {
        guard width > 0, height > 0 else {
            throw TraceProjectStoreError.invalidDimensions
        }

        let packageURL = uniquePackageURL(createdAt: createdAt, id: id)
        guard !FileManager.default.fileExists(atPath: packageURL.path) else {
            throw TraceProjectStoreError.packageAlreadyExists
        }

        let rawDirectory = packageURL.appendingPathComponent("raw", isDirectory: true)
        let eventsDirectory = packageURL.appendingPathComponent("events", isDirectory: true)
        let analysisDirectory = packageURL.appendingPathComponent("analysis", isDirectory: true)
        let editsDirectory = packageURL.appendingPathComponent("edits", isDirectory: true)
        let previewsDirectory = packageURL.appendingPathComponent("previews", isDirectory: true)
        let videoURL = rawDirectory.appendingPathComponent("screen.mp4")
        let pointerURL = eventsDirectory.appendingPathComponent("pointer.jsonl")
        let clicksURL = eventsDirectory.appendingPathComponent("clicks.jsonl")
        let editPlanURL = editsDirectory.appendingPathComponent("edit-plan.json")

        do {
            for directory in [rawDirectory, eventsDirectory, analysisDirectory, editsDirectory, previewsDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            FileManager.default.createFile(atPath: pointerURL.path, contents: nil)
            FileManager.default.createFile(atPath: clicksURL.path, contents: nil)
            let planEncoder = JSONEncoder()
            planEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try planEncoder.encode(AutoEditPlan()).write(to: editPlanURL, options: .atomic)

            let manifest = TraceManifest(
                id: id,
                kind: .recording,
                createdAt: createdAt,
                title: "录屏 \(Self.displayTimestamp.string(from: createdAt))",
                state: .capturing,
                dimensions: TraceDimensions(width: width, height: height),
                assets: [
                    TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                    TraceAsset(role: .pointerEvents, relativePath: "events/pointer.jsonl"),
                    TraceAsset(role: .clickEvents, relativePath: "events/clicks.jsonl"),
                    TraceAsset(role: .editPlan, relativePath: "edits/edit-plan.json")
                ]
            )
            try writeManifest(manifest, to: packageURL)
            return RecordingTraceSession(
                packageURL: packageURL,
                videoURL: videoURL,
                pointerEventsURL: pointerURL,
                clickEventsURL: clicksURL,
                editPlanURL: editPlanURL,
                manifest: manifest
            )
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    public func finalizeRecording(
        _ session: RecordingTraceSession,
        durationSeconds: Double,
        state: TraceState = .processing
    ) throws -> SavedTrace {
        guard FileManager.default.fileExists(atPath: session.videoURL.path) else {
            throw TraceProjectStoreError.missingRawRecording
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: session.videoURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw TraceProjectStoreError.emptyRawRecording
        }
        var manifest = session.manifest
        manifest.state = state
        manifest.durationSeconds = max(0, durationSeconds)
        try writeManifest(manifest, to: session.packageURL)
        return SavedTrace(
            packageURL: session.packageURL,
            rawAssetURL: session.videoURL,
            manifest: manifest
        )
    }

    public func markRecordingInterrupted(_ session: RecordingTraceSession) throws {
        var manifest = session.manifest
        manifest.state = .interrupted
        try writeManifest(manifest, to: session.packageURL)
    }

    public func writeAutoEditPlan(
        for session: RecordingTraceSession,
        durationSeconds: Double
    ) throws -> AutoEditPlan {
        let clicks = try TraceEventReader.read(ClickEvent.self, from: session.clickEventsURL)
        let pointerEvents = try TraceEventReader.read(PointerEvent.self, from: session.pointerEventsURL)
        var plan = AutoEditPlan()
        plan.cursor.keyframes = CursorPathPlanner().plan(events: pointerEvents)
        plan.interaction?.clickPulses = clicks.compactMap { click in
            guard click.phase == .down, let position = click.normalizedLocation else { return nil }
            return AutoEditPlan.ClickPulse(
                time: click.time,
                position: position,
                button: click.button
            )
        }
        plan.camera.keyframes = AutoCameraPlanner().plan(
            clicks: clicks,
            duration: durationSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: session.editPlanURL, options: .atomic)
        return plan
    }

    public func recoverInterruptedRecordings() -> [RecordingRecoveryCandidate] {
        var recovered: [RecordingRecoveryCandidate] = []
        for url in tracePackageURLs(in: rootDirectory) {
            guard var manifest = try? loadManifest(from: url),
                  manifest.kind == .recording,
                  manifest.state == .capturing else {
                continue
            }
            manifest.state = .interrupted
            guard (try? writeManifest(manifest, to: url)) != nil else { continue }
            let videoURL = url.appendingPathComponent("raw/screen.mp4")
            recovered.append(RecordingRecoveryCandidate(
                packageURL: url,
                videoURL: videoURL,
                manifest: manifest
            ))
        }
        return recovered
    }

    public func completeProcessing(
        packageURL: URL,
        renderedVideoURL: URL
    ) throws -> SavedTrace {
        guard FileManager.default.fileExists(atPath: renderedVideoURL.path) else {
            throw TraceProjectStoreError.missingRenderedVideo
        }
        var manifest = try loadManifest(from: packageURL)
        manifest.state = .ready
        let relativePath = renderedVideoURL.path.replacingOccurrences(
            of: packageURL.path + "/",
            with: ""
        )
        if !manifest.assets.contains(where: { $0.role == .renderedVideo }) {
            manifest.assets.append(TraceAsset(role: .renderedVideo, relativePath: relativePath))
        }
        try writeManifest(manifest, to: packageURL)
        let rawAsset = manifest.assets.first(where: { $0.role == .screenVideo })
            .map { packageURL.appendingPathComponent($0.relativePath) }
            ?? packageURL.appendingPathComponent("raw/screen.mp4")
        return SavedTrace(packageURL: packageURL, rawAssetURL: rawAsset, manifest: manifest)
    }

    private func tracePackageURLs(in directory: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var packages: [URL] = []
        for child in children {
            if child.pathExtension == "screentrace" {
                packages.append(child)
                continue
            }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            packages.append(contentsOf: tracePackageURLs(in: child))
        }
        return packages
    }

    private func uniquePackageURL(createdAt: Date, id: UUID) -> URL {
        let dayDirectory = rootDirectory
            .appendingPathComponent(Self.dayFormatter.string(from: createdAt), isDirectory: true)
        let basename = "Trace-\(Self.filenameTimestamp.string(from: createdAt))-\(id.uuidString.prefix(8))"
        return dayDirectory.appendingPathComponent("\(basename).screentrace", isDirectory: true)
    }

    private func writeManifest(_ manifest: TraceManifest, to packageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func canonicalURLAllowingMissingComponents(_ url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existingAncestor.path),
              existingAncestor.path != "/" {
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        }
        var result = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let filenameTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let displayTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
