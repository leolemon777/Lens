import Foundation

public enum TraceProjectStoreError: LocalizedError, Equatable {
    case invalidDimensions
    case packageAlreadyExists
    case missingRawRecording
    case emptyRawRecording
    case missingRenderedVideo
    case missingRenderedScreenshot
    case emptyRenderedScreenshot
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
        case .missingRenderedScreenshot:
            return "标注后的截图文件不存在。"
        case .emptyRenderedScreenshot:
            return "标注后的截图文件为空。"
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

    public var libraryIndexURL: URL {
        rootDirectory
            .appendingPathComponent(".index", isDirectory: true)
            .appendingPathComponent("library-v1.json")
    }

    public func saveScreenshot(
        pngData: Data,
        width: Int,
        height: Int,
        titlePrefix: String = "截图",
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

            let normalizedTitlePrefix = titlePrefix
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = TraceManifest(
                id: id,
                kind: .screenshot,
                createdAt: createdAt,
                title: "\(normalizedTitlePrefix.isEmpty ? "截图" : normalizedTitlePrefix) \(Self.displayTimestamp.string(from: createdAt))",
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
        var plan = try JSONDecoder().decode(AutoEditPlan.self, from: data)
        if let manifest = try? loadManifest(from: packageURL),
           let duration = manifest.durationSeconds {
            plan.videoAnnotations = plan.videoAnnotations?.compactMap {
                $0.normalized(sourceDurationSeconds: duration)
            }
        }
        return plan
    }

    public func writeAutoEditPlan(
        _ requestedPlan: AutoEditPlan,
        to packageURL: URL
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: packageURL)
        guard manifest.kind == .recording else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }
        var plan = requestedPlan
        plan.schemaVersion = AutoEditPlan.currentSchemaVersion
        if let duration = manifest.durationSeconds,
           duration >= VideoEditTimeline.minimumSegmentDurationSeconds {
            plan.timeline = (plan.timeline ?? VideoEditTimeline(
                sourceDurationSeconds: duration
            )).normalized(sourceDurationSeconds: duration)
            plan.videoAnnotations = plan.videoAnnotations?.compactMap {
                $0.normalized(sourceDurationSeconds: duration)
            }
        }

        let relativePath = "edits/edit-plan.json"
        let outputURL = packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: outputURL, options: .atomic)

        if !manifest.assets.contains(where: { $0.role == .editPlan }) {
            manifest.assets.append(TraceAsset(role: .editPlan, relativePath: relativePath))
        }
        manifest.state = .processing
        try writeManifest(manifest, to: packageURL)
        let rawAssetURL = manifest.assets.first(where: { $0.role == .screenVideo })
            .map { packageURL.appendingPathComponent($0.relativePath) }
            ?? packageURL.appendingPathComponent("raw/screen.mp4")
        return SavedTrace(
            packageURL: packageURL,
            rawAssetURL: rawAssetURL,
            manifest: manifest
        )
    }

    public func loadRecordingSegmentIndex(from packageURL: URL) throws -> RecordingSegmentIndex {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("events/segments.json"))
        return try JSONDecoder().decode(RecordingSegmentIndex.self, from: data)
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

    public func attachTranscript(
        _ document: TranscriptDocument,
        to savedTrace: SavedTrace
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: savedTrace.packageURL)
        guard manifest.kind == .recording else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }
        manifest.schemaVersion = TraceManifest.currentSchemaVersion
        let relativePath = "analysis/transcript.json"
        let outputURL = savedTrace.packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: outputURL, options: .atomic)
        if !manifest.assets.contains(where: { $0.role == .transcript }) {
            manifest.assets.append(TraceAsset(role: .transcript, relativePath: relativePath))
        }
        try writeManifest(manifest, to: savedTrace.packageURL)
        return SavedTrace(
            packageURL: savedTrace.packageURL,
            rawAssetURL: savedTrace.rawAssetURL,
            manifest: manifest
        )
    }

    public func loadTranscript(from packageURL: URL) throws -> TranscriptDocument {
        let data = try Data(
            contentsOf: packageURL.appendingPathComponent("analysis/transcript.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: data)
    }

    public func attachInsights(
        _ document: TraceInsightsDocument,
        to savedTrace: SavedTrace
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: savedTrace.packageURL)
        manifest.schemaVersion = TraceManifest.currentSchemaVersion
        let relativePath = "analysis/insights.json"
        let outputURL = savedTrace.packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: outputURL, options: .atomic)
        if !manifest.assets.contains(where: { $0.role == .insights }) {
            manifest.assets.append(TraceAsset(role: .insights, relativePath: relativePath))
        }
        try writeManifest(manifest, to: savedTrace.packageURL)
        return SavedTrace(
            packageURL: savedTrace.packageURL,
            rawAssetURL: savedTrace.rawAssetURL,
            manifest: manifest
        )
    }

    public func loadInsights(from packageURL: URL) throws -> TraceInsightsDocument {
        let data = try Data(
            contentsOf: packageURL.appendingPathComponent("analysis/insights.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TraceInsightsDocument.self, from: data)
    }

    public func writeScreenshotEditPlan(
        _ plan: ScreenshotEditPlan,
        to savedTrace: SavedTrace
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: savedTrace.packageURL)
        guard manifest.kind == .screenshot else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }
        guard manifest.dimensions == plan.sourceDimensions else {
            throw TraceProjectStoreError.invalidDimensions
        }

        let relativePath = "edits/screenshot-edit.json"
        let outputURL = savedTrace.packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan).write(to: outputURL, options: .atomic)

        if !manifest.assets.contains(where: { $0.role == .screenshotEditPlan }) {
            manifest.assets.append(
                TraceAsset(role: .screenshotEditPlan, relativePath: relativePath)
            )
        }
        try writeManifest(manifest, to: savedTrace.packageURL)
        return SavedTrace(
            packageURL: savedTrace.packageURL,
            rawAssetURL: savedTrace.rawAssetURL,
            manifest: manifest
        )
    }

    public func loadScreenshotEditPlan(from packageURL: URL) throws -> ScreenshotEditPlan {
        let data = try Data(
            contentsOf: packageURL.appendingPathComponent("edits/screenshot-edit.json")
        )
        return try JSONDecoder().decode(ScreenshotEditPlan.self, from: data)
    }

    public func attachScrollingCapture(
        _ plan: ScrollingCapturePlan,
        framePNGs: [Data],
        to savedTrace: SavedTrace
    ) throws -> SavedTrace {
        var manifest = try loadManifest(from: savedTrace.packageURL)
        guard manifest.kind == .screenshot else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }
        guard !plan.frames.isEmpty,
              manifest.dimensions == plan.outputDimensions,
              plan.frames.count == framePNGs.count,
              plan.viewportDimensions.width > 0,
              plan.viewportDimensions.height > 0,
              plan.outputDimensions.width == plan.viewportDimensions.width,
              plan.outputDimensions.height >= plan.viewportDimensions.height,
              plan.sourceRect.x >= 0,
              plan.sourceRect.y >= 0,
              plan.sourceRect.width > 0,
              plan.sourceRect.height > 0 else {
            throw TraceProjectStoreError.invalidDimensions
        }

        var expectedVerticalOffset = 0
        for (position, frame) in plan.frames.enumerated() {
            let isFirstFrame = position == 0
            let validContribution = isFirstFrame
                ? frame.appendedHeightPixels == plan.viewportDimensions.height
                : frame.appendedHeightPixels > 0
                    && frame.appendedHeightPixels < plan.viewportDimensions.height
            if !isFirstFrame {
                expectedVerticalOffset += frame.appendedHeightPixels
            }
            guard frame.index == position,
                  frame.verticalOffsetPixels == expectedVerticalOffset,
                  validContribution else {
                throw TraceProjectStoreError.invalidDimensions
            }
        }
        guard plan.viewportDimensions.height + expectedVerticalOffset
                == plan.outputDimensions.height else {
            throw TraceProjectStoreError.invalidDimensions
        }

        let rawDirectory = savedTrace.packageURL.appendingPathComponent(
            "raw/scrolling",
            isDirectory: true
        )
        let planURL = savedTrace.packageURL.appendingPathComponent(
            "events/scrolling-capture.json"
        )
        guard !FileManager.default.fileExists(atPath: rawDirectory.path),
              !FileManager.default.fileExists(atPath: planURL.path) else {
            throw TraceProjectStoreError.packageAlreadyExists
        }
        let stagingID = UUID().uuidString
        let stagingDirectory = savedTrace.packageURL.appendingPathComponent(
            "raw/.scrolling-\(stagingID)",
            isDirectory: true
        )
        let stagingPlanURL = savedTrace.packageURL.appendingPathComponent(
            "events/.scrolling-\(stagingID).json"
        )
        var committedMedia = false
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            for (position, pair) in zip(plan.frames, framePNGs).enumerated() {
                let frame = pair.0
                let png = pair.1
                let expectedPath = String(
                    format: "raw/scrolling/frame-%03d.png",
                    position
                )
                guard frame.relativePath == expectedPath,
                      !png.isEmpty else {
                    throw TraceProjectStoreError.invalidDimensions
                }
                try png.write(
                    to: stagingDirectory.appendingPathComponent(
                        String(format: "frame-%03d.png", position)
                    ),
                    options: .atomic
                )
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(plan).write(to: stagingPlanURL, options: .atomic)
            try FileManager.default.moveItem(at: stagingDirectory, to: rawDirectory)
            committedMedia = true
            try FileManager.default.moveItem(at: stagingPlanURL, to: planURL)

            manifest.assets.removeAll {
                $0.role == .scrollingCaptureFrame || $0.role == .scrollingCapturePlan
            }
            manifest.assets.append(contentsOf: plan.frames.map {
                TraceAsset(role: .scrollingCaptureFrame, relativePath: $0.relativePath)
            })
            manifest.assets.append(
                TraceAsset(
                    role: .scrollingCapturePlan,
                    relativePath: "events/scrolling-capture.json"
                )
            )
            try writeManifest(manifest, to: savedTrace.packageURL)
            return SavedTrace(
                packageURL: savedTrace.packageURL,
                rawAssetURL: savedTrace.rawAssetURL,
                manifest: manifest
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? FileManager.default.removeItem(at: stagingPlanURL)
            if committedMedia {
                try? FileManager.default.removeItem(at: rawDirectory)
                try? FileManager.default.removeItem(at: planURL)
            }
            throw error
        }
    }

    public func loadScrollingCapturePlan(from packageURL: URL) throws -> ScrollingCapturePlan {
        let data = try Data(
            contentsOf: packageURL.appendingPathComponent("events/scrolling-capture.json")
        )
        return try JSONDecoder().decode(ScrollingCapturePlan.self, from: data)
    }

    public func completeScreenshotEditing(
        packageURL: URL,
        renderedImageURL: URL
    ) throws -> SavedTrace {
        guard FileManager.default.fileExists(atPath: renderedImageURL.path) else {
            throw TraceProjectStoreError.missingRenderedScreenshot
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: renderedImageURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw TraceProjectStoreError.emptyRenderedScreenshot
        }

        var manifest = try loadManifest(from: packageURL)
        guard manifest.kind == .screenshot else {
            throw TraceProjectStoreError.incompatibleTraceKind
        }
        let relativePath = renderedImageURL.path.replacingOccurrences(
            of: packageURL.path + "/",
            with: ""
        )
        if !manifest.assets.contains(where: { $0.role == .renderedScreenshot }) {
            manifest.assets.append(
                TraceAsset(role: .renderedScreenshot, relativePath: relativePath)
            )
        }
        manifest.state = .ready
        try writeManifest(manifest, to: packageURL)
        let rawAsset = manifest.assets.first(where: { $0.role == .screenshot })
            .map { packageURL.appendingPathComponent($0.relativePath) }
            ?? packageURL.appendingPathComponent("raw/screenshot.png")
        return SavedTrace(packageURL: packageURL, rawAssetURL: rawAsset, manifest: manifest)
    }

    /// Refreshes the disposable persistent index. Invalid packages are skipped; valid interrupted captures remain visible.
    public func libraryEntries() -> [TraceLibraryEntry] {
        TraceLibraryPersistentIndexStore(
            rootDirectory: rootDirectory,
            indexURL: libraryIndexURL
        ).entries(packageURLs: tracePackageURLs(in: rootDirectory))
    }

    public func beginRecording(
        width: Int,
        height: Int,
        captureSource: TraceCaptureMetadata? = nil,
        includesSystemAudio: Bool = true,
        includesMicrophone: Bool = false,
        includesCamera: Bool = false,
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
        let segmentIndexURL = eventsDirectory.appendingPathComponent("segments.json")
        let editPlanURL = editsDirectory.appendingPathComponent("edit-plan.json")
        let microphoneURL = includesMicrophone
            ? rawDirectory.appendingPathComponent("microphone.caf")
            : nil
        let cameraURL = includesCamera
            ? rawDirectory.appendingPathComponent("camera.mov")
            : nil

        do {
            for directory in [rawDirectory, eventsDirectory, analysisDirectory, editsDirectory, previewsDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            FileManager.default.createFile(atPath: pointerURL.path, contents: nil)
            FileManager.default.createFile(atPath: clicksURL.path, contents: nil)
            let firstSegment = RecordingSegment(
                index: 0,
                timelineStartSeconds: 0,
                screenRelativePath: "raw/screen.mp4",
                microphoneRelativePath: includesMicrophone ? "raw/microphone.caf" : nil,
                cameraRelativePath: includesCamera ? "raw/camera.mov" : nil
            )
            try writeRecordingSegmentIndex(
                RecordingSegmentIndex(segments: [firstSegment]),
                to: segmentIndexURL
            )
            let planEncoder = JSONEncoder()
            planEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var initialPlan = AutoEditPlan()
            initialPlan.presenterCamera?.isEnabled = includesCamera
            try planEncoder.encode(initialPlan).write(to: editPlanURL, options: .atomic)

            let titlePrefix: String = switch captureSource?.mode {
            case .region: "区域录屏"
            case .window:
                captureSource?.applicationName.map { "\($0) 窗口录屏" } ?? "窗口录屏"
            case .display: "屏幕录制"
            case nil: "录屏"
            }
            var assets = [
                TraceAsset(role: .screenVideo, relativePath: "raw/screen.mp4"),
                TraceAsset(role: .pointerEvents, relativePath: "events/pointer.jsonl"),
                TraceAsset(role: .clickEvents, relativePath: "events/clicks.jsonl"),
                TraceAsset(role: .recordingSegments, relativePath: "events/segments.json"),
                TraceAsset(role: .editPlan, relativePath: "edits/edit-plan.json")
            ]
            if includesSystemAudio {
                assets.append(
                    TraceAsset(role: .systemAudio, relativePath: "raw/screen.mp4")
                )
            }
            if includesMicrophone {
                assets.append(
                    TraceAsset(role: .microphone, relativePath: "raw/microphone.caf")
                )
            }
            if includesCamera {
                assets.append(
                    TraceAsset(role: .camera, relativePath: "raw/camera.mov")
                )
            }
            let manifest = TraceManifest(
                id: id,
                kind: .recording,
                createdAt: createdAt,
                title: "\(titlePrefix) \(Self.displayTimestamp.string(from: createdAt))",
                state: .capturing,
                dimensions: TraceDimensions(width: width, height: height),
                captureSource: captureSource,
                assets: assets
            )
            try writeManifest(manifest, to: packageURL)
            return RecordingTraceSession(
                packageURL: packageURL,
                videoURL: videoURL,
                pointerEventsURL: pointerURL,
                clickEventsURL: clicksURL,
                segmentIndexURL: segmentIndexURL,
                editPlanURL: editPlanURL,
                microphoneURL: microphoneURL,
                cameraURL: cameraURL,
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
        // Preserve assets that may have been added or removed while capture was active.
        var manifest = (try? loadManifest(from: session.packageURL)) ?? session.manifest
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
        var manifest = (try? loadManifest(from: session.packageURL)) ?? session.manifest
        manifest.state = .interrupted
        try writeManifest(manifest, to: session.packageURL)
    }

    public func removeAsset(
        role: TraceAsset.Role,
        from packageURL: URL
    ) throws {
        var manifest = try loadManifest(from: packageURL)
        manifest.assets.removeAll { $0.role == role }
        try writeManifest(manifest, to: packageURL)
    }

    public func upsertAsset(_ asset: TraceAsset, in packageURL: URL) throws {
        var manifest = try loadManifest(from: packageURL)
        manifest.assets.removeAll { $0.role == asset.role }
        manifest.assets.append(asset)
        try writeManifest(manifest, to: packageURL)
    }

    public func appendRecordingSegment(
        _ segment: RecordingSegment,
        to session: RecordingTraceSession
    ) throws {
        var index = try loadRecordingSegmentIndex(from: session.packageURL)
        index.segments.removeAll { $0.index == segment.index }
        index.segments.append(segment)
        index.segments.sort { $0.index < $1.index }
        try writeRecordingSegmentIndex(index, to: session.segmentIndexURL)

        var manifest = try loadManifest(from: session.packageURL)
        let assets = [
            TraceAsset(role: .screenVideoSegment, relativePath: segment.screenRelativePath),
            segment.microphoneRelativePath.map {
                TraceAsset(role: .microphoneSegment, relativePath: $0)
            },
            segment.cameraRelativePath.map {
                TraceAsset(role: .cameraSegment, relativePath: $0)
            }
        ].compactMap { $0 }
        for asset in assets where !manifest.assets.contains(where: {
            $0.role == asset.role && $0.relativePath == asset.relativePath
        }) {
            manifest.assets.append(asset)
        }
        try writeManifest(manifest, to: session.packageURL)
    }

    @discardableResult
    public func completeRecordingSegment(
        index segmentIndex: Int,
        durationSeconds: Double,
        in session: RecordingTraceSession
    ) throws -> RecordingSegmentIndex {
        var index = try loadRecordingSegmentIndex(from: session.packageURL)
        guard let position = index.segments.firstIndex(where: { $0.index == segmentIndex }) else {
            return index
        }
        index.segments[position].durationSeconds = max(0, durationSeconds)
        try writeRecordingSegmentIndex(index, to: session.segmentIndexURL)
        return index
    }

    public func discardRecordingSegment(
        index segmentIndex: Int,
        from session: RecordingTraceSession
    ) throws {
        var index = try loadRecordingSegmentIndex(from: session.packageURL)
        guard let segment = index.segments.first(where: { $0.index == segmentIndex }) else { return }
        index.segments.removeAll { $0.index == segmentIndex }
        try writeRecordingSegmentIndex(index, to: session.segmentIndexURL)

        let paths = [
            segment.screenRelativePath,
            segment.microphoneRelativePath,
            segment.cameraRelativePath
        ].compactMap { $0 }
        var manifest = try loadManifest(from: session.packageURL)
        manifest.assets.removeAll { asset in
            paths.contains(asset.relativePath) && [
                TraceAsset.Role.screenVideoSegment,
                .microphoneSegment,
                .cameraSegment
            ].contains(asset.role)
        }
        try writeManifest(manifest, to: session.packageURL)
    }

    public func removeRecordingSegmentMedia(
        role: TraceAsset.Role,
        segmentIndex: Int,
        from session: RecordingTraceSession
    ) throws {
        guard role == .microphone || role == .camera else { return }
        var index = try loadRecordingSegmentIndex(from: session.packageURL)
        guard let position = index.segments.firstIndex(where: { $0.index == segmentIndex }) else {
            return
        }
        let relativePath: String?
        let manifestRole: TraceAsset.Role
        switch role {
        case .microphone:
            relativePath = index.segments[position].microphoneRelativePath
            index.segments[position].microphoneRelativePath = nil
            manifestRole = segmentIndex == 0 ? .microphone : .microphoneSegment
        case .camera:
            relativePath = index.segments[position].cameraRelativePath
            index.segments[position].cameraRelativePath = nil
            manifestRole = segmentIndex == 0 ? .camera : .cameraSegment
        default:
            return
        }
        try writeRecordingSegmentIndex(index, to: session.segmentIndexURL)
        guard let relativePath else { return }
        var manifest = try loadManifest(from: session.packageURL)
        manifest.assets.removeAll {
            $0.role == manifestRole && $0.relativePath == relativePath
        }
        try writeManifest(manifest, to: session.packageURL)
    }

    public func writeAutoEditPlan(
        for session: RecordingTraceSession,
        durationSeconds: Double
    ) throws -> AutoEditPlan {
        let clicks = try TraceEventReader.read(ClickEvent.self, from: session.clickEventsURL)
        let pointerEvents = try TraceEventReader.read(PointerEvent.self, from: session.pointerEventsURL)
        var plan = (try? loadAutoEditPlan(from: session.packageURL)) ?? AutoEditPlan()
        plan.schemaVersion = AutoEditPlan.currentSchemaVersion
        plan.timeline = (plan.timeline ?? VideoEditTimeline(
            sourceDurationSeconds: durationSeconds
        )).normalized(sourceDurationSeconds: durationSeconds)
        plan.videoAnnotations = plan.videoAnnotations?.compactMap {
            $0.normalized(sourceDurationSeconds: durationSeconds)
        }
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
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var packages: [URL] = []
        for child in children {
            guard let values = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else {
                continue
            }
            if child.pathExtension == "screentrace" {
                if values.isDirectory == true { packages.append(child) }
                continue
            }
            guard values.isDirectory == true else { continue }
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

    private func writeRecordingSegmentIndex(
        _ index: RecordingSegmentIndex,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(index).write(to: url, options: .atomic)
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
