import Foundation
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testRecentScreenshotRestoresOnceWithoutOverwritingANewerCapture() throws {
        let suiteName = "ScreenTraceRecentRestoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
        let oldEntry = makeScreenshotEntry(root: root, title: "较早截图")
        let image = NSImage(size: NSSize(width: 64, height: 36))

        XCTAssertTrue(model.restoreRecentTraceIfAbsent(oldEntry, thumbnail: image))
        XCTAssertEqual(model.recentTrace?.id, oldEntry.id)
        XCTAssertEqual(model.recentTrace?.imageURL, oldEntry.displayAssetURL)

        let newerTrace = SavedTrace(
            packageURL: root.appendingPathComponent("new.screentrace"),
            rawAssetURL: root.appendingPathComponent("new.png"),
            manifest: TraceManifest(
                kind: .screenshot,
                title: "刚完成的截图",
                dimensions: TraceDimensions(width: 1_200, height: 800),
                assets: [TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png")]
            )
        )
        model.setRecentTrace(newerTrace, thumbnail: image)

        XCTAssertFalse(model.restoreRecentTraceIfAbsent(oldEntry, thumbnail: image))
        XCTAssertEqual(model.recentTrace?.id, newerTrace.manifest.id)
    }

    func testRecordingMediaPreferencesPersistWithSafeDefaults() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppModel(defaults: defaults)
        XCTAssertTrue(initial.capturesSystemAudio)
        XCTAssertFalse(initial.capturesMicrophone)
        XCTAssertFalse(initial.capturesCamera)
        XCTAssertEqual(initial.recordingFrameRate, .fps60)
        XCTAssertEqual(initial.recordingExperiencePreset, .natural)
        XCTAssertTrue(initial.automaticallyTranscribesRecordings)
        XCTAssertEqual(initial.transcriptionLanguage, .automatic)
        XCTAssertEqual(initial.quickScreenshotShortcut, .defaultQuickScreenshot)
        XCTAssertEqual(initial.actionCenterShortcut, .defaultActionCenter)

        initial.capturesSystemAudio = false
        initial.capturesMicrophone = true
        initial.capturesCamera = true
        initial.recordingFrameRate = .fps30
        initial.recordingExperiencePreset = .teaching
        initial.automaticallyTranscribesRecordings = false
        initial.transcriptionLanguage = .simplifiedChinese
        initial.quickScreenshotShortcut = HotKeyShortcut(
            keyCode: 8,
            modifiers: [.command, .shift]
        )
        initial.actionCenterShortcut = HotKeyShortcut(
            keyCode: 9,
            modifiers: [.control, .option]
        )
        let restored = AppModel(defaults: defaults)

        XCTAssertFalse(restored.capturesSystemAudio)
        XCTAssertTrue(restored.capturesMicrophone)
        XCTAssertFalse(restored.capturesCamera)
        XCTAssertEqual(restored.recordingFrameRate, .fps30)
        XCTAssertEqual(restored.recordingExperiencePreset, .teaching)
        XCTAssertFalse(restored.automaticallyTranscribesRecordings)
        XCTAssertEqual(restored.transcriptionLanguage, .simplifiedChinese)
        XCTAssertEqual(
            restored.quickScreenshotShortcut,
            HotKeyShortcut(keyCode: 8, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            restored.actionCenterShortcut,
            HotKeyShortcut(keyCode: 9, modifiers: [.control, .option])
        )
    }

    func testPreviousReleasePreferencesLoadWhileCameraOptInResetsSafely() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quick = HotKeyShortcut(keyCode: 18, modifiers: [.command, .option])
        let center = HotKeyShortcut(keyCode: 19, modifiers: [.control, .shift])
        defaults.set(false, forKey: "recording.capturesSystemAudio")
        defaults.set(true, forKey: "recording.capturesMicrophone")
        defaults.set(true, forKey: "recording.capturesCamera")
        defaults.set(30, forKey: "recording.framesPerSecond")
        defaults.set(false, forKey: "analysis.automaticallyTranscribesRecordings")
        defaults.set("english", forKey: "analysis.transcriptionLanguage")
        defaults.set(try JSONEncoder().encode(quick), forKey: "shortcuts.quickScreenshot")
        defaults.set(try JSONEncoder().encode(center), forKey: "shortcuts.actionCenter")

        let upgraded = AppModel(defaults: defaults)
        XCTAssertFalse(upgraded.capturesSystemAudio)
        XCTAssertTrue(upgraded.capturesMicrophone)
        XCTAssertFalse(upgraded.capturesCamera)
        XCTAssertFalse(defaults.bool(forKey: "recording.capturesCamera"))
        XCTAssertEqual(upgraded.recordingFrameRate, .fps30)
        XCTAssertFalse(upgraded.automaticallyTranscribesRecordings)
        XCTAssertEqual(upgraded.transcriptionLanguage, .english)
        XCTAssertEqual(upgraded.quickScreenshotShortcut, quick)
        XCTAssertEqual(upgraded.actionCenterShortcut, center)
    }

    func testRecordingExperiencePresetsConfigureDistinctAutomaticEdits() {
        let natural = RecordingExperiencePreset.natural.makeEditPlan(includesCamera: false)
        XCTAssertEqual(natural.preset, "natural")
        XCTAssertTrue(natural.camera.followPointer)
        XCTAssertEqual(natural.camera.zoomIntensity, 0.42, accuracy: 0.001)
        XCTAssertEqual(natural.camera.zoomScale, 1.60)
        XCTAssertEqual(natural.camera.generationStrength, .restrained)
        XCTAssertEqual(natural.camera.motionBlurStrength, 0.12, accuracy: 0.001)
        XCTAssertEqual(natural.cursor.smoothingWindowMilliseconds, 42)
        XCTAssertEqual(natural.cursor.appearance, .recorded)
        XCTAssertEqual(natural.cursor.motionEffect, .halo)
        XCTAssertEqual(natural.cursor.motionEffectStrength, 0.50)
        XCTAssertFalse(natural.cursor.hidesWhenIdle)
        XCTAssertEqual(natural.interaction?.clickEffect, .ripple)
        XCTAssertEqual(natural.interaction?.clickPulseScale, 1.25)
        XCTAssertEqual(natural.interaction?.clickPulseColorHex, "#FF684D")
        XCTAssertEqual(natural.interaction?.clickPulseDuration, 0.64)
        XCTAssertTrue(natural.cursor.isEnabled == true)
        XCTAssertFalse(natural.presenterCamera?.isEnabled == true)
        XCTAssertFalse(natural.captions?.isEnabled == true)
        XCTAssertEqual(natural.export?.preset, .balanced)

        let presentation = RecordingExperiencePreset.presentation.makeEditPlan(
            includesCamera: true
        )
        XCTAssertGreaterThan(
            presentation.camera.zoomIntensity,
            natural.camera.zoomIntensity
        )
        XCTAssertEqual(presentation.camera.zoomScale, 1.60)
        XCTAssertEqual(presentation.camera.generationStrength, .active)
        XCTAssertGreaterThan(
            presentation.camera.motionBlurStrength,
            natural.camera.motionBlurStrength
        )
        XCTAssertEqual(presentation.cursor.smoothingWindowMilliseconds, 52)
        XCTAssertEqual(presentation.cursor.appearance, .highContrast)
        XCTAssertEqual(presentation.cursor.motionEffect, .trail)
        XCTAssertEqual(presentation.interaction?.clickEffect, .pulse)
        XCTAssertEqual(presentation.interaction?.clickPulseDuration, 0.58)
        XCTAssertFalse(presentation.cursor.hidesWhenIdle)
        XCTAssertTrue(presentation.presenterCamera?.isEnabled == true)
        XCTAssertEqual(presentation.canvas?.backgroundTopHex, "#667EEA")
        XCTAssertEqual(presentation.export?.preset, .balanced)

        let teaching = RecordingExperiencePreset.teaching.makeEditPlan(includesCamera: true)
        XCTAssertEqual(teaching.camera.zoomScale, 1.60)
        XCTAssertTrue(teaching.audio?.reducesMicrophoneNoise == true)
        XCTAssertEqual(teaching.camera.generationStrength, .balanced)
        XCTAssertFalse(teaching.cursor.hidesWhenIdle)
        XCTAssertEqual(teaching.cursor.appearance, .recorded)
        XCTAssertEqual(teaching.cursor.motionEffect, .spotlight)
        XCTAssertEqual(teaching.interaction?.clickEffect, .spotlight)
        XCTAssertTrue(teaching.audio?.ducksSystemUnderNarration == true)
        XCTAssertEqual(teaching.captions?.style, .glass)
        XCTAssertTrue(
            teaching.captions?.isEnabled == true,
            "教学讲解档发出去必须自带字幕，不应再让用户进编辑器打开"
        )
        XCTAssertEqual(teaching.export?.preset, .balanced)

        let source = RecordingExperiencePreset.source.makeEditPlan(includesCamera: true)
        XCTAssertEqual(source.camera.mode, "off")
        XCTAssertEqual(source.camera.motionBlurStrength, 0)
        XCTAssertEqual(source.cursor.smoothingWindowMilliseconds, 0)
        XCTAssertFalse(source.camera.followPointer)
        XCTAssertFalse(source.cursor.isEnabled == true)
        XCTAssertEqual(source.cursor.motionEffect, .none)
        XCTAssertFalse(source.canvas?.isEnabled == true)
        XCTAssertFalse(source.presenterCamera?.isEnabled == true)
        XCTAssertEqual(source.export?.preset, .source)
    }

    func testUnsupportedStoredFrameRateFallsBackToSixtyFPS() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(120, forKey: "recording.framesPerSecond")

        XCTAssertEqual(AppModel(defaults: defaults).recordingFrameRate, .fps60)
    }

    func testUnsupportedStoredTranscriptionLanguageFallsBackToAutomatic() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("elvish", forKey: "analysis.transcriptionLanguage")

        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguage, .automatic)
    }

    func testTranscriptionLanguagesMapToStableSpeechLocales() {
        XCTAssertEqual(TranscriptionLanguage.simplifiedChinese.localeIdentifier, "zh-CN")
        XCTAssertEqual(TranscriptionLanguage.traditionalChinese.localeIdentifier, "zh-TW")
        XCTAssertEqual(TranscriptionLanguage.english.localeIdentifier, "en-US")
        XCTAssertEqual(TranscriptionLanguage.japanese.localeIdentifier, "ja-JP")
        XCTAssertEqual(TranscriptionLanguage.korean.localeIdentifier, "ko-KR")
        XCTAssertFalse(TranscriptionLanguage.automatic.localeIdentifier.isEmpty)
    }

    func testAutomaticTranscriptionLocaleNormalizesChineseScriptWithoutUsingUSRegion() {
        XCTAssertEqual(
            TranscriptionLanguage.automaticLocaleIdentifier(for: "zh-Hans-US"),
            "zh-CN"
        )
        XCTAssertEqual(
            TranscriptionLanguage.automaticLocaleIdentifier(for: "zh-Hant-US"),
            "zh-TW"
        )
    }

    func testCorruptOrConflictingStoredShortcutsFallBackToDefaults() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "shortcuts.quickScreenshot")
        defaults.set(
            try JSONEncoder().encode(HotKeyShortcut.defaultQuickScreenshot),
            forKey: "shortcuts.actionCenter"
        )

        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.quickScreenshotShortcut, .defaultQuickScreenshot)
        XCTAssertEqual(model.actionCenterShortcut, .defaultActionCenter)
        XCTAssertTrue(model.hotKeyConfiguration.isValid)
    }

    func testRestoreDefaultShortcutsPersistsBothBindings() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        model.quickScreenshotShortcut = HotKeyShortcut(
            keyCode: 8,
            modifiers: [.command, .shift]
        )
        model.actionCenterShortcut = HotKeyShortcut(
            keyCode: 9,
            modifiers: [.control, .option]
        )

        model.restoreDefaultShortcuts()
        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.quickScreenshotShortcut, .defaultQuickScreenshot)
        XCTAssertEqual(restored.actionCenterShortcut, .defaultActionCenter)
    }

    private func makeScreenshotEntry(root: URL, title: String) -> TraceLibraryEntry {
        let id = UUID()
        let package = root.appendingPathComponent("\(id).screentrace", isDirectory: true)
        let raw = package.appendingPathComponent("raw/screenshot.png")
        let rendered = package.appendingPathComponent("renders/final.png")
        return TraceLibraryEntry(
            packageURL: package,
            manifest: TraceManifest(
                id: id,
                kind: .screenshot,
                title: title,
                dimensions: TraceDimensions(width: 960, height: 540),
                assets: [
                    TraceAsset(role: .screenshot, relativePath: "raw/screenshot.png"),
                    TraceAsset(role: .renderedScreenshot, relativePath: "renders/final.png")
                ]
            ),
            primaryAssetURL: raw,
            displayAssetURL: rendered,
            ocrText: nil
        )
    }
}
