import AppKit
import Foundation
import ScreenTraceCore

enum RecordingFrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case simplifiedChinese
    case traditionalChinese
    case english
    case japanese
    case korean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动 · 跟随系统"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .automatic: Locale.current.identifier
        case .simplifiedChinese: "zh-CN"
        case .traditionalChinese: "zh-TW"
        case .english: "en-US"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct RecentTrace: Identifiable {
        let id: UUID
        let title: String
        let packageURL: URL
        let imageURL: URL
        let dimensions: TraceDimensions
        let thumbnail: NSImage
    }

    private enum PreferenceKey {
        static let capturesSystemAudio = "recording.capturesSystemAudio"
        static let capturesMicrophone = "recording.capturesMicrophone"
        static let capturesCamera = "recording.capturesCamera"
        static let frameRate = "recording.framesPerSecond"
        static let automaticallyTranscribesRecordings = "analysis.automaticallyTranscribesRecordings"
        static let transcriptionLanguage = "analysis.transcriptionLanguage"
        static let quickScreenshotShortcut = "shortcuts.quickScreenshot"
        static let actionCenterShortcut = "shortcuts.actionCenter"
    }

    private let defaults: UserDefaults
    @Published private(set) var recentTrace: RecentTrace?
    @Published var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: PreferenceKey.capturesSystemAudio) }
    }
    @Published var capturesMicrophone: Bool {
        didSet { defaults.set(capturesMicrophone, forKey: PreferenceKey.capturesMicrophone) }
    }
    @Published var capturesCamera: Bool {
        didSet { defaults.set(capturesCamera, forKey: PreferenceKey.capturesCamera) }
    }
    @Published var recordingFrameRate: RecordingFrameRate {
        didSet { defaults.set(recordingFrameRate.rawValue, forKey: PreferenceKey.frameRate) }
    }
    @Published var automaticallyTranscribesRecordings: Bool {
        didSet {
            defaults.set(
                automaticallyTranscribesRecordings,
                forKey: PreferenceKey.automaticallyTranscribesRecordings
            )
        }
    }
    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { defaults.set(transcriptionLanguage.rawValue, forKey: PreferenceKey.transcriptionLanguage) }
    }
    @Published var quickScreenshotShortcut: HotKeyShortcut {
        didSet { persistShortcut(quickScreenshotShortcut, forKey: PreferenceKey.quickScreenshotShortcut) }
    }
    @Published var actionCenterShortcut: HotKeyShortcut {
        didSet { persistShortcut(actionCenterShortcut, forKey: PreferenceKey.actionCenterShortcut) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        capturesSystemAudio = defaults.object(forKey: PreferenceKey.capturesSystemAudio) as? Bool ?? true
        capturesMicrophone = defaults.object(forKey: PreferenceKey.capturesMicrophone) as? Bool ?? false
        capturesCamera = defaults.object(forKey: PreferenceKey.capturesCamera) as? Bool ?? false
        recordingFrameRate = RecordingFrameRate(
            rawValue: defaults.integer(forKey: PreferenceKey.frameRate)
        ) ?? .fps60
        automaticallyTranscribesRecordings = defaults.object(
            forKey: PreferenceKey.automaticallyTranscribesRecordings
        ) as? Bool ?? true
        transcriptionLanguage = defaults.string(forKey: PreferenceKey.transcriptionLanguage)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .automatic
        let storedConfiguration = HotKeyConfiguration(
            quickScreenshot: Self.loadShortcut(
                from: defaults,
                key: PreferenceKey.quickScreenshotShortcut
            ) ?? .defaultQuickScreenshot,
            actionCenter: Self.loadShortcut(
                from: defaults,
                key: PreferenceKey.actionCenterShortcut
            ) ?? .defaultActionCenter
        )
        let configuration = storedConfiguration.isValid ? storedConfiguration : .default
        quickScreenshotShortcut = configuration.quickScreenshot
        actionCenterShortcut = configuration.actionCenter
    }

    var hotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            quickScreenshot: quickScreenshotShortcut,
            actionCenter: actionCenterShortcut
        )
    }

    func restoreDefaultShortcuts() {
        quickScreenshotShortcut = .defaultQuickScreenshot
        actionCenterShortcut = .defaultActionCenter
    }

    private func persistShortcut(_ shortcut: HotKeyShortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadShortcut(from defaults: UserDefaults, key: String) -> HotKeyShortcut? {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
              shortcut.isValid else { return nil }
        return shortcut
    }

    func setRecentTrace(_ savedTrace: SavedTrace, thumbnail: NSImage) {
        guard let dimensions = savedTrace.manifest.dimensions else { return }
        recentTrace = RecentTrace(
            id: savedTrace.manifest.id,
            title: savedTrace.manifest.title,
            packageURL: savedTrace.packageURL,
            imageURL: savedTrace.rawAssetURL,
            dimensions: dimensions,
            thumbnail: thumbnail
        )
    }
}
