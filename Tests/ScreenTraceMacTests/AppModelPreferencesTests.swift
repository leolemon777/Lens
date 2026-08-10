import Foundation
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testRecordingMediaPreferencesPersistWithSafeDefaults() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppModel(defaults: defaults)
        XCTAssertTrue(initial.capturesSystemAudio)
        XCTAssertFalse(initial.capturesMicrophone)
        XCTAssertFalse(initial.capturesCamera)
        XCTAssertEqual(initial.recordingFrameRate, .fps60)
        XCTAssertTrue(initial.automaticallyTranscribesRecordings)
        XCTAssertEqual(initial.transcriptionLanguage, .automatic)
        XCTAssertEqual(initial.quickScreenshotShortcut, .defaultQuickScreenshot)
        XCTAssertEqual(initial.actionCenterShortcut, .defaultActionCenter)

        initial.capturesSystemAudio = false
        initial.capturesMicrophone = true
        initial.capturesCamera = true
        initial.recordingFrameRate = .fps30
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
        XCTAssertTrue(restored.capturesCamera)
        XCTAssertEqual(restored.recordingFrameRate, .fps30)
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

    func testPreviousReleasePreferenceKeysLoadWithoutMigrationOrReset() throws {
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
        XCTAssertTrue(upgraded.capturesCamera)
        XCTAssertEqual(upgraded.recordingFrameRate, .fps30)
        XCTAssertFalse(upgraded.automaticallyTranscribesRecordings)
        XCTAssertEqual(upgraded.transcriptionLanguage, .english)
        XCTAssertEqual(upgraded.quickScreenshotShortcut, quick)
        XCTAssertEqual(upgraded.actionCenterShortcut, center)
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
}
