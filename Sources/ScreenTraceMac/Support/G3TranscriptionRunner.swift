@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech
import ScreenTraceCore

struct G3TranscriptionConfiguration {
    let audioURL: URL
    let reportURL: URL
    let localeIdentifier: String
    let expectedTerms: [String]
    let verifiesOrganization: Bool

    init?(arguments: [String], workingDirectory: URL? = nil) {
        guard arguments.contains("--g3-transcription"),
              let audioPath = Self.option("--audio", in: arguments),
              let reportPath = Self.option("--report", in: arguments) else {
            return nil
        }
        let baseURL = workingDirectory ?? URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        audioURL = Self.resolve(audioPath, relativeTo: baseURL)
        reportURL = Self.resolve(reportPath, relativeTo: baseURL)
        let requestedLocale = Self.option("--locale", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        localeIdentifier = requestedLocale.isEmpty ? "zh-CN" : requestedLocale
        expectedTerms = Self.option("--expected-terms", in: arguments)?
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        verifiesOrganization = arguments.contains("--verify-organization")
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

struct G3TranscriptionAcceptance: Equatable {
    let audioDurationSeconds: Double
    let audioRootMeanSquare: Double
    let document: TranscriptDocument
    let matchedExpectedTermCount: Int
    let expectedTermCount: Int
    let organizationRequired: Bool
    let organizationVerified: Bool

    var timelineIsValid: Bool {
        var previousStart = 0.0
        for segment in document.segments {
            guard segment.startSeconds >= previousStart - 0.001,
                  segment.endSeconds > segment.startSeconds,
                  segment.endSeconds <= audioDurationSeconds + 0.35 else {
                return false
            }
            previousStart = segment.startSeconds
        }
        return true
    }

    var passed: Bool {
        audioDurationSeconds >= 0.5
            && audioRootMeanSquare > 0.000_05
            && document.isOnDevice
            && !document.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !document.segments.isEmpty
            && timelineIsValid
            && matchedExpectedTermCount == expectedTermCount
            && (!organizationRequired || organizationVerified)
    }
}

private struct G3TranscriptionGateReport: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let gate: String
    let result: String
    let evidenceLevel: String
    let build: BuildIdentity
    let localeIdentifier: String
    let authorizationStatus: Int
    let audioDurationSeconds: Double
    let audioRootMeanSquare: Double
    let isOnDevice: Bool
    let sourceRole: TraceAsset.Role
    let segmentCount: Int
    let recognizedCharacterCount: Int
    let averageConfidence: Double
    let timelineIsValid: Bool
    let expectedTermCount: Int
    let matchedExpectedTermCount: Int
    let organizationRequired: Bool
    let organizationVerified: Bool
    let organizationTagCount: Int
    let organizationKeyPointCount: Int
    let organizationChapterCount: Int
    let processingDurationMilliseconds: Double
}

private struct G3TranscriptionFailureReport: Encodable {
    let schemaVersion = 1
    let generatedAt = Date()
    let gate = "G3-transcription"
    let result = "failed"
    let evidenceLevel: String
    let build: BuildIdentity
    let authorizationStatus: Int
    let reason: String
}

/// Privacy-safe installed-app gate. The report stores counts and timing only;
/// recognized words and expected phrases are deliberately excluded.
@MainActor
enum G3TranscriptionRunner {
    static func run(_ configuration: G3TranscriptionConfiguration) async -> Int32 {
        let installed = Bundle.main.bundleURL.standardizedFileURL.path
            .hasPrefix("/Applications/")
        let evidenceLevel = installed
            ? "E4-installed-native-app"
            : "E2-real-media-native-app-bundle"
        let build = BuildIdentity.current
        let startedAt = ProcessInfo.processInfo.systemUptime
        var authorization = LocalSpeechTranscriptionService.authorizationStatus
        if authorization == .notDetermined {
            authorization = await LocalSpeechTranscriptionService.requestAuthorization()
        }
        do {
            let asset = AVURLAsset(url: configuration.audioURL)
            let duration = try await asset.load(.duration).seconds
            let evidence = await AudioMediaEvidenceAnalyzer.analyze(
                url: configuration.audioURL
            )
            let document = try await LocalSpeechTranscriptionService().transcribe(
                audioURL: configuration.audioURL,
                localeIdentifier: configuration.localeIdentifier,
                sourceRole: .microphone
            )
            let normalizedText = normalize(document.fullText)
            let matchedExpectedTermCount = configuration.expectedTerms.filter {
                normalizedText.contains(normalize($0))
            }.count
            let insights = LocalTraceOrganizer.organize(
                manifest: TraceManifest(
                    kind: .recording,
                    title: "G3 本机转写验证",
                    durationSeconds: duration,
                    dimensions: nil,
                    assets: [TraceAsset(
                        role: .microphone,
                        relativePath: "controlled-audio"
                    )]
                ),
                transcript: document
            )
            let organizationVerified = verifyOrganization(
                insights,
                durationSeconds: duration
            )
            let acceptance = G3TranscriptionAcceptance(
                audioDurationSeconds: duration,
                audioRootMeanSquare: evidence?.rootMeanSquare ?? 0,
                document: document,
                matchedExpectedTermCount: matchedExpectedTermCount,
                expectedTermCount: configuration.expectedTerms.count,
                organizationRequired: configuration.verifiesOrganization,
                organizationVerified: organizationVerified
            )
            let confidences = document.segments.map(\.confidence)
            let report = G3TranscriptionGateReport(
                schemaVersion: 1,
                generatedAt: Date(),
                gate: "G3-transcription",
                result: acceptance.passed ? "passed" : "failed",
                evidenceLevel: evidenceLevel,
                build: build,
                localeIdentifier: document.localeIdentifier,
                authorizationStatus: authorization.rawValue,
                audioDurationSeconds: duration,
                audioRootMeanSquare: evidence?.rootMeanSquare ?? 0,
                isOnDevice: document.isOnDevice,
                sourceRole: document.sourceRole,
                segmentCount: document.segments.count,
                recognizedCharacterCount: document.fullText.count,
                averageConfidence: confidences.isEmpty
                    ? 0
                    : confidences.reduce(0, +) / Double(confidences.count),
                timelineIsValid: acceptance.timelineIsValid,
                expectedTermCount: configuration.expectedTerms.count,
                matchedExpectedTermCount: matchedExpectedTermCount,
                organizationRequired: configuration.verifiesOrganization,
                organizationVerified: organizationVerified,
                organizationTagCount: insights.tags.count,
                organizationKeyPointCount: insights.keyPoints.count,
                organizationChapterCount: insights.chapters.count,
                processingDurationMilliseconds: max(
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                    0
                )
            )
            try write(report, to: configuration.reportURL)
            return acceptance.passed ? 0 : 1
        } catch {
            let report = G3TranscriptionFailureReport(
                evidenceLevel: evidenceLevel,
                build: build,
                authorizationStatus: authorization.rawValue,
                reason: error.localizedDescription
            )
            try? write(report, to: configuration.reportURL)
            return 1
        }
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    nonisolated private static func verifyOrganization(
        _ insights: TraceInsightsDocument,
        durationSeconds: Double
    ) -> Bool {
        guard insights.engine == LocalTraceOrganizer.engineIdentifier,
              !insights.suggestedTitle.isEmpty,
              !insights.summary.isEmpty,
              !insights.tags.isEmpty,
              !insights.chapters.isEmpty else { return false }
        var previousStart = 0.0
        for chapter in insights.chapters {
            guard chapter.startSeconds >= previousStart - 0.001,
                  chapter.endSeconds > chapter.startSeconds,
                  chapter.endSeconds <= durationSeconds + 0.35,
                  !chapter.title.isEmpty else { return false }
            previousStart = chapter.startSeconds
        }
        return true
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
}
