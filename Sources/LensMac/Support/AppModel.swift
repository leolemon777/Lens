import AppKit
import Foundation
import LensCore

enum RecordingFrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }
}

enum RecordingExperiencePreset: String, CaseIterable, Identifiable, Sendable {
    case natural
    case presentation
    case teaching
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: "自然成片"
        case .presentation: "聚焦演示"
        case .teaching: "教学讲解"
        case .source: "原始录制"
        }
    }

    var subtitle: String {
        switch self {
        case .natural: "平滑缩放、光标与点击反馈"
        case .presentation: "更强聚焦，适合产品演示"
        case .teaching: "讲解声、字幕与人像优先"
        case .source: "不加效果，只保留独立原始轨"
        }
    }

    var symbol: String {
        switch self {
        case .natural: "sparkles"
        case .presentation: "scope"
        case .teaching: "person.wave.2"
        case .source: "film.stack"
        }
    }

    func makeEditPlan(includesCamera: Bool) -> AutoEditPlan {
        var plan = AutoEditPlan(preset: rawValue)
        switch self {
        case .natural:
            plan.camera.mode = "event-driven"
            plan.camera.zoomIntensity = 0.42
            plan.camera.zoomScale = 1.60
            plan.camera.generationStrength = .restrained
            plan.camera.motionBlurStrength = 0
            plan.camera.clickToZoom = true
            plan.camera.followPointer = true
            plan.cursor.isEnabled = true
            // The default path should feel faithful to the user's real input.
            // Smoothing and glow remain available in the presentation/teaching
            // presets, but must not make an ordinary recording feel delayed.
            plan.cursor.smoothing = 0
            plan.cursor.smoothingWindowMilliseconds = nil
            plan.cursor.followStyle = .faithful
            plan.cursor.scale = 1.15
            plan.cursor.hidesWhenIdle = false
            plan.cursor.appearance = .recorded
            plan.cursor.motionEffect = .none
            plan.interaction?.showsClickPulse = true
            plan.interaction?.clickEffect = .ripple
            plan.interaction?.clickEffectStrength = 1
            plan.interaction?.clickPulseScale = 1.25
            plan.interaction?.clickPulseColorHex = "#FF684D"
            plan.interaction?.clickPulseDuration = 0.64
            plan.canvas?.isEnabled = true
            // Shareable H.264 at source resolution. Compact is HEVC and often
            // fails in chat apps; source quality is reserved for the archive preset.
            plan.export?.preset = .balanced
        case .presentation:
            plan.camera.mode = "event-driven"
            plan.camera.zoomIntensity = 0.62
            plan.camera.zoomScale = 1.60
            plan.camera.generationStrength = .active
            plan.camera.motionBlurStrength = 0
            plan.camera.clickToZoom = true
            plan.camera.followPointer = true
            plan.cursor.isEnabled = true
            plan.cursor.smoothing = 0.78
            plan.cursor.smoothingWindowMilliseconds = 30
            plan.cursor.scale = 1.28
            plan.cursor.hidesWhenIdle = false
            plan.cursor.appearance = .highContrast
            plan.cursor.motionEffect = .halo
            plan.cursor.motionEffectStrength = 0.28
            plan.interaction?.showsClickPulse = true
            plan.interaction?.clickEffect = .pulse
            plan.interaction?.clickEffectStrength = 0.96
            plan.interaction?.clickPulseScale = 1.30
            plan.interaction?.clickPulseColorHex = "#FF684D"
            plan.interaction?.clickPulseDuration = 0.58
            plan.canvas = AutoEditPlan.Canvas(
                isEnabled: true,
                margin: 0.065,
                cornerRadius: 0.032,
                shadowOpacity: 0.32,
                backgroundTopHex: "#667EEA",
                backgroundBottomHex: "#764BA2"
            )
            // Shareable H.264 at source resolution. Compact is HEVC and often
            // fails in chat apps; source quality is reserved for the archive preset.
            plan.export?.preset = .balanced
        case .teaching:
            plan.camera.mode = "event-driven"
            plan.camera.zoomIntensity = 0.50
            plan.camera.zoomScale = 1.60
            plan.camera.generationStrength = .balanced
            plan.camera.motionBlurStrength = 0
            plan.camera.clickToZoom = true
            plan.camera.followPointer = true
            plan.cursor.isEnabled = true
            plan.cursor.smoothing = 0.76
            plan.cursor.smoothingWindowMilliseconds = 28
            plan.cursor.scale = 1.22
            plan.cursor.hidesWhenIdle = false
            plan.cursor.appearance = .recorded
            plan.cursor.motionEffect = .halo
            plan.cursor.motionEffectStrength = 0.28
            plan.interaction?.showsClickPulse = true
            plan.interaction?.clickEffect = .spotlight
            plan.interaction?.clickEffectStrength = 0.90
            plan.interaction?.clickPulseScale = 1.25
            plan.interaction?.clickPulseColorHex = "#FF684D"
            plan.interaction?.clickPulseDuration = 0.64
            plan.audio = AutoEditPlan.Audio(
                reducesMicrophoneNoise: true,
                noiseReductionAmount: 0.62,
                normalizesLoudness: true,
                targetLoudnessLUFS: -16,
                ducksSystemUnderNarration: true,
                duckedSystemVolume: 0.28
            )
            plan.captions = AutoEditPlan.Captions(
                isEnabled: true,
                style: .glass,
                position: .bottom,
                fontScale: 1.08,
                maxCharactersPerCue: 24
            )
            // Shareable H.264 at source resolution. Compact is HEVC and often
            // fails in chat apps; source quality is reserved for the archive preset.
            plan.export?.preset = .balanced
        case .source:
            plan.camera.mode = "off"
            plan.camera.zoomIntensity = 0
            plan.camera.zoomScale = 1
            plan.camera.clickToZoom = false
            plan.camera.followPointer = false
            plan.camera.motionBlurStrength = 0
            plan.cursor.isEnabled = false
            plan.cursor.smoothingWindowMilliseconds = 0
            plan.cursor.motionEffect = .none
            plan.interaction?.showsClickPulse = false
            plan.canvas?.isEnabled = false
            plan.presenterCamera?.isEnabled = false
            plan.audio?.reducesMicrophoneNoise = false
            plan.audio?.normalizesLoudness = false
            plan.audio?.ducksSystemUnderNarration = false
            plan.export?.preset = .source
        }
        if self != .source {
            plan.presenterCamera?.isEnabled = includesCamera
        }
        return plan
    }
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
        case .automatic:
            Self.automaticLocaleIdentifier(
                for: Locale.preferredLanguages.first ?? Locale.current.identifier
            )
        case .simplifiedChinese: "zh-CN"
        case .traditionalChinese: "zh-TW"
        case .english: "en-US"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        }
    }

    static func automaticLocaleIdentifier(for preferredLanguageIdentifier: String) -> String {
        let locale = Locale(identifier: preferredLanguageIdentifier)
        switch locale.language.languageCode?.identifier {
        case "zh":
            let script = locale.language.script?.identifier
            let region = locale.region?.identifier
            return script == "Hant" || ["HK", "MO", "TW"].contains(region) ? "zh-TW" : "zh-CN"
        case "en":
            return "en-US"
        case "ja":
            return "ja-JP"
        case "ko":
            return "ko-KR"
        default:
            return locale.identifier.replacingOccurrences(of: "_", with: "-")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct RecentLens: Identifiable {
        let id: UUID
        let title: String
        let packageURL: URL
        let imageURL: URL
        let dimensions: LensDimensions
        let thumbnail: NSImage
    }

    private enum PreferenceKey {
        static let capturesSystemAudio = "recording.capturesSystemAudio"
        static let capturesMicrophone = "recording.capturesMicrophone"
        static let capturesCamera = "recording.capturesCamera"
        static let frameRate = "recording.framesPerSecond"
        static let showsRecordingCountdown = "recording.showsCountdown"
        static let experiencePreset = "recording.experiencePreset"
        static let automaticallyTranscribesRecordings = "analysis.automaticallyTranscribesRecordings"
        static let transcriptionLanguage = "analysis.transcriptionLanguage"
        static let quickScreenshotShortcut = "shortcuts.quickScreenshot"
        static let actionCenterShortcut = "shortcuts.actionCenter"
        static let conversationInboxShortcut = "shortcuts.conversationInbox"
        static let conversationInboxDirectory = "inbox.directoryPath"
    }

    private let defaults: UserDefaults
    @Published private(set) var recentLens: RecentLens?
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
    @Published var showsRecordingCountdown: Bool {
        didSet {
            defaults.set(showsRecordingCountdown, forKey: PreferenceKey.showsRecordingCountdown)
        }
    }
    @Published var recordingExperiencePreset: RecordingExperiencePreset {
        didSet {
            defaults.set(
                recordingExperiencePreset.rawValue,
                forKey: PreferenceKey.experiencePreset
            )
        }
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
    @Published var conversationInboxShortcut: HotKeyShortcut {
        didSet { persistShortcut(conversationInboxShortcut, forKey: PreferenceKey.conversationInboxShortcut) }
    }
    @Published var conversationInboxDirectory: URL {
        didSet {
            defaults.set(
                conversationInboxDirectory.path,
                forKey: PreferenceKey.conversationInboxDirectory
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        capturesSystemAudio = defaults.object(forKey: PreferenceKey.capturesSystemAudio) as? Bool ?? true
        capturesMicrophone = defaults.object(forKey: PreferenceKey.capturesMicrophone) as? Bool ?? false
        // Camera capture is deliberately opt-in for every app session. A previous
        // release persisted this toggle, which could unexpectedly start the next
        // recording with the front camera active.
        capturesCamera = false
        defaults.set(false, forKey: PreferenceKey.capturesCamera)
        recordingFrameRate = RecordingFrameRate(
            rawValue: defaults.integer(forKey: PreferenceKey.frameRate)
        ) ?? .fps60
        showsRecordingCountdown = defaults.object(
            forKey: PreferenceKey.showsRecordingCountdown
        ) as? Bool ?? true
        recordingExperiencePreset = defaults.string(forKey: PreferenceKey.experiencePreset)
            .flatMap(RecordingExperiencePreset.init(rawValue:)) ?? .natural
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
            ) ?? .defaultActionCenter,
            conversationInbox: Self.loadShortcut(
                from: defaults,
                key: PreferenceKey.conversationInboxShortcut
            ) ?? .defaultConversationInbox
        )
        let configuration = storedConfiguration.isValid ? storedConfiguration : .default
        quickScreenshotShortcut = configuration.quickScreenshot
        actionCenterShortcut = configuration.actionCenter
        conversationInboxShortcut = configuration.conversationInbox
        conversationInboxDirectory = ConversationInboxStore.resolvedDirectory(
            storedPath: defaults.string(forKey: PreferenceKey.conversationInboxDirectory)
        )
    }

    var hotKeyConfiguration: HotKeyConfiguration {
        HotKeyConfiguration(
            quickScreenshot: quickScreenshotShortcut,
            actionCenter: actionCenterShortcut,
            conversationInbox: conversationInboxShortcut
        )
    }

    func restoreDefaultShortcuts() {
        quickScreenshotShortcut = .defaultQuickScreenshot
        actionCenterShortcut = .defaultActionCenter
        conversationInboxShortcut = .defaultConversationInbox
    }

    func restoreDefaultConversationInboxDirectory() {
        conversationInboxDirectory = ConversationInboxStore.defaultDirectory()
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

    func setRecentLens(_ savedLens: SavedLens, thumbnail: NSImage) {
        guard let dimensions = savedLens.manifest.dimensions else { return }
        recentLens = RecentLens(
            id: savedLens.manifest.id,
            title: savedLens.manifest.title,
            packageURL: savedLens.packageURL,
            imageURL: savedLens.rawAssetURL,
            dimensions: dimensions,
            thumbnail: thumbnail
        )
    }

    /// Restores the latest screenshot after launch without overwriting a capture
    /// that completed while the persistent library was still loading.
    @discardableResult
    func restoreRecentLensIfAbsent(
        _ entry: LensLibraryEntry,
        thumbnail: NSImage
    ) -> Bool {
        guard recentLens == nil,
              entry.manifest.kind == .screenshot,
              entry.manifest.state == .ready,
              let dimensions = entry.manifest.dimensions else { return false }
        recentLens = RecentLens(
            id: entry.id,
            title: entry.manifest.title,
            packageURL: entry.packageURL,
            imageURL: entry.displayAssetURL,
            dimensions: dimensions,
            thumbnail: thumbnail
        )
        return true
    }
}
