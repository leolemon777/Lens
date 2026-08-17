@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import ScreenTraceCore

struct G3RenderedEffectsConfiguration {
    let projectURL: URL
    let reportURL: URL
    let outputURL: URL?
    let preset: AutoEditPlan.Export.Preset?
    let enablesCaptions: Bool
    let diagnosticCaptionText: String?
    let addsVideoAnnotation: Bool
    let persistsDerivedCopy: Bool
    let requiredEffects: [RenderedEffectKind]

    init?(arguments: [String], workingDirectory: URL? = nil) {
        guard arguments.contains("--g3-rendered-effects"),
              let projectPath = Self.option("--project", in: arguments),
              let reportPath = Self.option("--report", in: arguments) else {
            return nil
        }
        let baseURL = workingDirectory ?? URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        projectURL = Self.resolve(projectPath, relativeTo: baseURL)
        reportURL = Self.resolve(reportPath, relativeTo: baseURL)
        outputURL = Self.option("--output", in: arguments).map {
            Self.resolve($0, relativeTo: baseURL)
        }
        if let presetValue = Self.option("--preset", in: arguments) {
            guard let parsed = AutoEditPlan.Export.Preset(rawValue: presetValue) else {
                return nil
            }
            preset = parsed
        } else {
            preset = nil
        }
        enablesCaptions = arguments.contains("--enable-captions")
        diagnosticCaptionText = Self.option("--caption-text", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        addsVideoAnnotation = arguments.contains("--add-video-annotation")
        persistsDerivedCopy = arguments.contains("--persist-derived-copy")
        if let requiredValue = Self.option("--require-effects", in: arguments) {
            let values = requiredValue.split(separator: ",").map(String.init)
            let parsed = values.compactMap(RenderedEffectKind.init(rawValue:))
            guard !values.isEmpty, parsed.count == values.count else { return nil }
            requiredEffects = Array(
                Dictionary(grouping: parsed, by: \.rawValue).values.compactMap(\.first)
            ).sorted { $0.rawValue < $1.rawValue }
        } else {
            requiredEffects = []
        }
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func resolve(_ path: String, relativeTo baseURL: URL) -> URL {
        URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
    }
}

struct G3RenderedEffectsAcceptance: Equatable {
    let outputExists: Bool
    let requestedEffectCount: Int
    let requiredEffects: [RenderedEffectKind]
    let verification: RenderedEffectVerificationReport
    let motionComfort: CameraMotionComfortReport
    let persistenceRequested: Bool
    let persistenceVerified: Bool
    let sourceProjectUnchanged: Bool
    let exportFreshnessVerified: Bool

    var passed: Bool {
        outputExists
            && requestedEffectCount > 0
            && verification.isVerified
            && motionComfort.isComfortable
            && (!persistenceRequested || persistenceVerified)
            && sourceProjectUnchanged
            && exportFreshnessVerified
            && requiredEffects.allSatisfy { required in
                verification.effects.contains {
                    $0.effect.rawValue == required.rawValue && $0.state == .verified
                }
            }
    }
}

private struct G3ProjectFingerprint: Encodable, Equatable {
    let regularFileCount: Int
    let totalFileBytes: UInt64
    let sha256: String
}

private struct G3RenderedEffectsGateReport: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let gate: String
    let result: String
    let evidenceLevel: String
    let build: BuildIdentity
    let projectID: String
    let preset: AutoEditPlan.Export.Preset
    let renderDurationMilliseconds: Double
    let outputFileBytes: UInt64
    let requestedEffectCount: Int
    let verifiedEffectCount: Int
    let requiredEffects: [RenderedEffectKind]
    let captionEvidenceSource: String
    let videoAnnotationEvidenceSource: String
    let persistenceRequested: Bool
    let persistenceVerified: Bool
    let persistedAssetRoleCount: Int
    let editorModelAuthored: Bool
    let editorMutationCount: Int
    let reopenedEditorVerified: Bool
    let renderedPlanDigest: String
    let exportFreshnessVerified: Bool
    let sourceProjectUnchanged: Bool
    let sourceProjectFingerprintBefore: G3ProjectFingerprint
    let sourceProjectFingerprintAfter: G3ProjectFingerprint
    let motionComfort: CameraMotionComfortReport
    let renderedEffectVerification: RenderedEffectVerificationReport
}

private struct G3RenderedEffectsFailureReport: Encodable {
    let schemaVersion = 1
    let generatedAt = Date()
    let gate = "G3"
    let result = "failed"
    let evidenceLevel: String
    let build: BuildIdentity
    let reason: String
}

/// Installed-app gate for proving that authored effects reach decoded output.
/// It never mutates the source project: rendering happens in a caller-provided
/// destination or an ephemeral sibling file that is deleted after verification.
@MainActor
enum G3RenderedEffectsRunner {
    static func run(_ configuration: G3RenderedEffectsConfiguration) async -> Int32 {
        let isInstalledApplication = Bundle.main.bundleURL.standardizedFileURL.path
            .hasPrefix("/Applications/")
        let evidenceLevel = isInstalledApplication
            ? "E4-installed-native-app"
            : "E2-real-media-native-app-bundle"
        let build = BuildIdentity.current
        let outputURL = configuration.outputURL
            ?? configuration.reportURL.deletingLastPathComponent()
                .appendingPathComponent(".g3-rendered-\(UUID().uuidString).mp4")
        let ownsOutput = configuration.outputURL == nil
        defer {
            if ownsOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        do {
            let sourceFingerprintBefore = try projectFingerprint(
                at: configuration.projectURL
            )
            let workingProjectURL: URL
            if configuration.persistsDerivedCopy {
                workingProjectURL = configuration.projectURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        ".g3-roundtrip-\(UUID().uuidString).screentrace",
                        isDirectory: true
                    )
                try FileManager.default.copyItem(
                    at: configuration.projectURL,
                    to: workingProjectURL
                )
            } else {
                workingProjectURL = configuration.projectURL
            }
            defer {
                if configuration.persistsDerivedCopy {
                    try? FileManager.default.removeItem(at: workingProjectURL)
                }
            }
            let store = TraceProjectStore(
                rootDirectory: workingProjectURL.deletingLastPathComponent()
            )
            var manifest = try store.loadManifest(from: workingProjectURL)
            guard manifest.kind == .recording else {
                throw GateError.notRecording
            }
            guard let rawURL = mediaURL(
                role: .screenVideo,
                fallbackRelativePath: "raw/screen.mp4",
                packageURL: workingProjectURL,
                manifest: manifest
            ) else {
                throw GateError.missingScreenVideo
            }
            var plan = try store.loadAutoEditPlan(from: workingProjectURL)
            if let preset = configuration.preset,
               !configuration.persistsDerivedCopy {
                if plan.export == nil { plan.export = .init(preset: preset) }
                plan.export?.preset = preset
            }
            if configuration.enablesCaptions,
               !configuration.persistsDerivedCopy {
                if plan.captions == nil { plan.captions = .init() }
                plan.captions?.isEnabled = true
            }
            if configuration.addsVideoAnnotation,
               !configuration.persistsDerivedCopy {
                let duration = max(manifest.durationSeconds ?? 4, 1)
                plan.videoAnnotations = [VideoAnnotation(
                    annotation: ScreenshotAnnotation(
                        kind: .rectangle,
                        bounds: TraceRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64),
                        style: ScreenshotAnnotationStyle(
                            lineWidth: 0.018,
                            color: .orange
                        )
                    ),
                    sourceStartSeconds: min(0.8, duration * 0.2),
                    sourceEndSeconds: min(max(duration - 0.1, 1.4), 4.6),
                    fadeDurationSeconds: 0.12
                )]
            }
            let cameraURL = mediaURL(
                role: .camera,
                fallbackRelativePath: "raw/camera.mov",
                packageURL: workingProjectURL,
                manifest: manifest
            )
            let microphoneURL = mediaURL(
                role: .microphone,
                fallbackRelativePath: "raw/microphone.caf",
                packageURL: workingProjectURL,
                manifest: manifest
            )
            let storedTranscript = try? store.loadTranscript(
                from: workingProjectURL
            )
            var transcript: TranscriptDocument?
            let captionEvidenceSource: String
            if let diagnosticCaptionText = configuration.diagnosticCaptionText {
                let duration = max(manifest.durationSeconds ?? 4, 1)
                transcript = TranscriptDocument(
                    engine: "g3-authored-caption-evidence",
                    localeIdentifier: "zh-Hans",
                    isOnDevice: true,
                    sourceRole: .screenVideo,
                    segments: [TranscriptSegment(
                        startSeconds: min(0.6, duration * 0.15),
                        endSeconds: min(max(duration - 0.1, 0.9), 4.2),
                        text: diagnosticCaptionText,
                        confidence: 1
                    )]
                )
                captionEvidenceSource = "diagnosticAuthoredText"
            } else {
                transcript = storedTranscript
                captionEvidenceSource = storedTranscript?.segments.isEmpty == false
                    ? "projectTranscript"
                    : "none"
            }

            var persistenceVerified = !configuration.persistsDerivedCopy
            var persistedAssetRoleCount = 0
            var editorModelAuthored = false
            var editorMutationCount = 0
            var reopenedEditorVerified = !configuration.persistsDerivedCopy
            if configuration.persistsDerivedCopy {
                guard let authoredTranscript = transcript else {
                    throw GateError.persistenceRequiresTranscript
                }
                let duration = max(manifest.durationSeconds ?? 0, 0)
                let editorModel = VideoEditorModel(
                    plan: plan,
                    sourceDurationSeconds: duration,
                    hasCameraTrack: cameraURL != nil,
                    hasMicrophoneTrack: microphoneURL != nil,
                    transcript: authoredTranscript
                )
                if let requestedPreset = configuration.preset {
                    editorModel.setExportPreset(requestedPreset)
                }
                editorModel.setAutomaticZoomScale(1.65)
                let regeneratedCamera = try store.regeneratedAutomaticCameraKeyframes(
                    from: workingProjectURL,
                    durationSeconds: duration,
                    camera: editorModel.plan.camera
                )
                editorModel.replaceAutomaticCameraKeyframes(with: regeneratedCamera)
                editorModel.setCursorEnabled(true)
                editorModel.setCursorAppearance(.highContrast)
                editorModel.setCursorMotionEffect(.trail)
                editorModel.setCursorMotionEffectStrength(0.46)
                editorModel.setCursorScale(1.18)
                editorModel.setClickPulseEnabled(true)
                editorModel.setClickEffect(.spotlight)
                editorModel.setClickEffectStrength(0.74)
                if configuration.enablesCaptions {
                    editorModel.setCaptionsEnabled(true)
                    editorModel.setCaptionStyle(.clean)
                    editorModel.setCaptionPosition(.bottom)
                    editorModel.setCaptionFontScale(1.12)
                    if !editorModel.captionSourceCues.isEmpty {
                        editorModel.setCaptionCueText(
                            "\(configuration.diagnosticCaptionText ?? "字幕") · 已校对",
                            at: 0
                        )
                    }
                }
                if configuration.addsVideoAnnotation {
                    editorModel.selectedVideoAnnotationColor = .orange
                    editorModel.defaultVideoAnnotationDurationSeconds = min(
                        max(duration - 0.9, 1.6),
                        3.8
                    )
                    editorModel.activateVideoAnnotationTool(.rectangle)
                    guard editorModel.commitVideoAnnotationDraft(
                        start: TracePoint(x: 0.18, y: 0.18),
                        end: TracePoint(x: 0.82, y: 0.82),
                        atOutputTime: min(0.8, duration * 0.2)
                    ) else {
                        throw GateError.editorMutationFailed
                    }
                }
                plan = editorModel.plan
                let expectedPreset = configuration.preset ?? plan.export?.preset ?? .source
                let editorChecks = [
                    abs(plan.camera.resolvedZoomScale - 1.65) < 0.000_1,
                    plan.camera.keyframes.contains { $0.reason != .baseline },
                    plan.export?.preset == expectedPreset,
                    plan.cursor.isEnabled != false,
                    plan.cursor.appearance == .highContrast,
                    plan.cursor.motionEffect == .trail,
                    abs(plan.cursor.motionEffectStrength - 0.46) < 0.000_1,
                    abs(plan.cursor.scale - 1.18) < 0.000_1,
                    plan.interaction?.showsClickPulse == true,
                    plan.interaction?.clickEffect == .spotlight,
                    abs((plan.interaction?.clickEffectStrength ?? 0) - 0.74) < 0.000_1,
                    !configuration.enablesCaptions || plan.captions?.isEnabled == true,
                    !configuration.enablesCaptions || plan.captions?.customCues?.isEmpty == false,
                    !configuration.addsVideoAnnotation || plan.videoAnnotations?.isEmpty == false
                ]
                editorMutationCount = editorChecks.filter { $0 }.count
                editorModelAuthored = editorMutationCount == editorChecks.count
                guard editorModelAuthored else {
                    throw GateError.editorMutationFailed
                }
                var savedTrace = try store.writeAutoEditPlan(
                    plan,
                    to: workingProjectURL
                )
                savedTrace = try store.attachTranscript(
                    authoredTranscript,
                    to: savedTrace
                )
                let insights = LocalTraceOrganizer.organize(
                    manifest: savedTrace.manifest,
                    transcript: authoredTranscript
                )
                savedTrace = try store.attachInsights(insights, to: savedTrace)

                manifest = try store.loadManifest(from: workingProjectURL)
                let reloadedPlan = try store.loadAutoEditPlan(from: workingProjectURL)
                let reloadedTranscript = try store.loadTranscript(from: workingProjectURL)
                let reloadedInsights = try store.loadInsights(from: workingProjectURL)
                let reopenedEditor = VideoEditorModel(
                    plan: reloadedPlan,
                    sourceDurationSeconds: duration,
                    hasCameraTrack: cameraURL != nil,
                    hasMicrophoneTrack: microphoneURL != nil,
                    transcript: reloadedTranscript
                )
                let requiredRoles: Set<TraceAsset.Role> = [
                    .editPlan, .transcript, .insights
                ]
                let persistedRoles = Set(manifest.assets.map(\.role))
                persistedAssetRoleCount = requiredRoles.intersection(persistedRoles).count
                reopenedEditorVerified = reopenedEditor.plan == reloadedPlan
                    && abs(reopenedEditor.plan.camera.resolvedZoomScale - 1.65) < 0.000_1
                    && reopenedEditor.plan.cursor.appearance == .highContrast
                    && reopenedEditor.plan.cursor.motionEffect == .trail
                    && reopenedEditor.plan.interaction?.clickEffect == .spotlight
                    && (!configuration.enablesCaptions
                        || reopenedEditor.plan.captions?.customCues?.isEmpty == false)
                    && (!configuration.addsVideoAnnotation
                        || reopenedEditor.videoAnnotations.isEmpty == false)
                persistenceVerified = reloadedPlan == plan
                    && reloadedTranscript == authoredTranscript
                    && reloadedInsights == insights
                    && persistedAssetRoleCount == requiredRoles.count
                    && editorModelAuthored
                    && reopenedEditorVerified
                guard persistenceVerified else {
                    throw GateError.persistenceRoundTripMismatch
                }
                plan = reloadedPlan
                transcript = reloadedTranscript
            }
            let preset = plan.export?.preset ?? .source

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            let renderer = AutoPreviewRenderer()
            _ = try await renderer.render(
                inputURL: rawURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                plan: plan,
                transcript: transcript
            )
            if let audio = plan.audio,
               AudioMixdownRenderer.requiresMixdown(
                   microphoneURL: microphoneURL,
                   plan: audio
               ) {
                let mixedURL = outputURL.deletingLastPathComponent()
                    .appendingPathComponent(".g3-mixed-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: mixedURL) }
                _ = try await AudioMixdownRenderer().render(
                    inputURL: outputURL,
                    microphoneURL: microphoneURL,
                    outputURL: mixedURL,
                    plan: audio,
                    timeline: plan.timeline,
                    export: plan.export
                )
                _ = try FileManager.default.replaceItemAt(
                    outputURL,
                    withItemAt: mixedURL
                )
            }
            let verification = await RenderedEffectVerifier(renderer: renderer).validate(
                rawURL: rawURL,
                previewURL: outputURL,
                plan: plan,
                cameraURL: cameraURL,
                microphoneURL: microphoneURL,
                transcript: transcript
            )
            let motionComfort = CameraMotionComfortAnalyzer.analyze(
                camera: plan.camera,
                durationSeconds: manifest.durationSeconds
                    ?? verification.previewDurationSeconds
                    ?? 0
            )
            let renderedPlanDigest = try RenderedPlanIdentity.digest(
                for: plan,
                transcript: transcript
            )
            let exportEvidence = RecordingHealthReport(
                requestedFramesPerSecond: Int((
                    verification.rawMeasuredFramesPerSecond ?? 30
                ).rounded()),
                measuredFramesPerSecond: verification.rawMeasuredFramesPerSecond,
                p95FrameIntervalMilliseconds: nil,
                droppedFrameCount: 0,
                videoStatus: .healthy,
                eventStatus: .notMeasured,
                pointerEventCount: 0,
                clickEventCount: 0,
                keyboardEventCount: 0,
                windowEventCount: 0,
                effectiveCameraKeyframeCount: plan.camera.keyframes.count,
                cursorKeyframeCount: plan.cursor.keyframes.count,
                clickPulseCount: plan.interaction?.clickPulses.count ?? 0,
                warnings: []
            ).addingRenderedEffectVerification(
                verification,
                renderedPlanDigest: renderedPlanDigest
            )
            var stalePlan = plan
            stalePlan.cursor.scale = plan.cursor.scale >= 2.9
                ? plan.cursor.scale - 0.11
                : plan.cursor.scale + 0.11
            let stalePlanDigest = try RenderedPlanIdentity.digest(
                for: stalePlan,
                transcript: transcript
            )
            let exportFreshnessVerified = RenderedPreviewExportGate.failureDescription(
                for: exportEvidence,
                expectedPlanDigest: renderedPlanDigest
            ) == nil && RenderedPreviewExportGate.failureDescription(
                for: exportEvidence,
                expectedPlanDigest: stalePlanDigest
            ) != nil
            let outputFileBytes = fileSize(at: outputURL)
            let sourceFingerprintAfter = try projectFingerprint(
                at: configuration.projectURL
            )
            let sourceProjectUnchanged = sourceFingerprintAfter == sourceFingerprintBefore
            let requestedEffectCount = verification.effects.filter {
                $0.state != .notRequested
            }.count
            let acceptance = G3RenderedEffectsAcceptance(
                outputExists: outputFileBytes > 0,
                requestedEffectCount: requestedEffectCount,
                requiredEffects: configuration.requiredEffects,
                verification: verification,
                motionComfort: motionComfort,
                persistenceRequested: configuration.persistsDerivedCopy,
                persistenceVerified: persistenceVerified,
                sourceProjectUnchanged: sourceProjectUnchanged,
                exportFreshnessVerified: exportFreshnessVerified
            )
            let report = G3RenderedEffectsGateReport(
                schemaVersion: 1,
                generatedAt: Date(),
                gate: "G3",
                result: acceptance.passed ? "passed" : "failed",
                evidenceLevel: evidenceLevel,
                build: build,
                projectID: manifest.id.uuidString,
                preset: preset,
                renderDurationMilliseconds: max(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                    0
                ),
                outputFileBytes: outputFileBytes,
                requestedEffectCount: requestedEffectCount,
                verifiedEffectCount: verification.verifiedEffects.count,
                requiredEffects: configuration.requiredEffects,
                captionEvidenceSource: captionEvidenceSource,
                videoAnnotationEvidenceSource: configuration.addsVideoAnnotation
                    ? "diagnosticAuthoredOverlay"
                    : (plan.videoAnnotations?.isEmpty == false
                        ? "projectEditPlan"
                        : "none"),
                persistenceRequested: configuration.persistsDerivedCopy,
                persistenceVerified: persistenceVerified,
                persistedAssetRoleCount: persistedAssetRoleCount,
                editorModelAuthored: editorModelAuthored,
                editorMutationCount: editorMutationCount,
                reopenedEditorVerified: reopenedEditorVerified,
                renderedPlanDigest: renderedPlanDigest,
                exportFreshnessVerified: exportFreshnessVerified,
                sourceProjectUnchanged: sourceProjectUnchanged,
                sourceProjectFingerprintBefore: sourceFingerprintBefore,
                sourceProjectFingerprintAfter: sourceFingerprintAfter,
                motionComfort: motionComfort,
                renderedEffectVerification: verification
            )
            try write(report, to: configuration.reportURL)
            return acceptance.passed ? 0 : 1
        } catch {
            let report = G3RenderedEffectsFailureReport(
                evidenceLevel: evidenceLevel,
                build: build,
                reason: error.localizedDescription
            )
            try? write(report, to: configuration.reportURL)
            return 1
        }
    }

    private static func mediaURL(
        role: TraceAsset.Role,
        fallbackRelativePath: String,
        packageURL: URL,
        manifest: TraceManifest
    ) -> URL? {
        let candidates = manifest.assets.filter { $0.role == role }.map {
            packageURL.appendingPathComponent($0.relativePath)
        } + [packageURL.appendingPathComponent(fallbackRelativePath)]
        return candidates.first {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 }
                == true
        }
    }

    private static func fileSize(at url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.uint64Value ?? 0
    }

    private static func projectFingerprint(at packageURL: URL) throws
        -> G3ProjectFingerprint {
        guard let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            throw GateError.cannotFingerprintSource
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { lhs, rhs in
            lhs.path < rhs.path
        }
        var packageHasher = SHA256()
        var totalFileBytes: UInt64 = 0
        for fileURL in files {
            let relativePath = String(fileURL.path.dropFirst(packageURL.path.count + 1))
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var fileHasher = SHA256()
            var fileBytes: UInt64 = 0
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                fileHasher.update(data: chunk)
                fileBytes += UInt64(chunk.count)
            }
            totalFileBytes += fileBytes
            let fileDigest = fileHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            packageHasher.update(data: Data(relativePath.utf8))
            packageHasher.update(data: Data([0]))
            packageHasher.update(data: Data(fileDigest.utf8))
            packageHasher.update(data: Data([0]))
        }
        return G3ProjectFingerprint(
            regularFileCount: files.count,
            totalFileBytes: totalFileBytes,
            sha256: packageHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func write<T: Encodable>(_ report: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private enum GateError: LocalizedError {
        case notRecording
        case missingScreenVideo
        case persistenceRequiresTranscript
        case persistenceRoundTripMismatch
        case cannotFingerprintSource
        case editorMutationFailed

        var errorDescription: String? {
            switch self {
            case .notRecording: "G3 只能验证录屏项目。"
            case .missingScreenVideo: "录屏项目缺少非空的原始屏幕视频。"
            case .persistenceRequiresTranscript: "保存重开验证需要非空字幕文本。"
            case .persistenceRoundTripMismatch: "字幕、标注、整理结果保存后重载不一致。"
            case .cannotFingerprintSource: "无法为原项目生成完整内容指纹。"
            case .editorMutationFailed: "编辑器操作没有完整进入待保存计划。"
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
