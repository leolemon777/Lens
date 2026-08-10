import AppKit
import Carbon
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

@MainActor
final class GlobalHotKeyManagerTests: XCTestCase {
    func testCarbonModifierMappingPreservesEverySupportedModifier() {
        let mapped = GlobalHotKeyManager.carbonModifiers([
            .function, .control, .option, .shift, .command
        ])
        XCTAssertNotEqual(mapped & UInt32(kEventKeyModifierFnMask), 0)
        XCTAssertNotEqual(mapped & UInt32(controlKey), 0)
        XCTAssertNotEqual(mapped & UInt32(optionKey), 0)
        XCTAssertNotEqual(mapped & UInt32(shiftKey), 0)
        XCTAssertNotEqual(mapped & UInt32(cmdKey), 0)

        XCTAssertEqual(
            GlobalHotKeyManager.modifiers(from: [.function, .control, .option, .shift, .command]),
            [.function, .control, .option, .shift, .command]
        )
    }

    func testRegistrationConflictsEnableEventMonitorFallback() {
        let manager = GlobalHotKeyManager(
            configuration: .default,
            installEventHandlerOverride: { true },
            registerOverride: { _, _ in OSStatus(eventHotKeyExistsErr) },
            handler: { _ in }
        )
        let report = manager.start()
        defer { manager.stop() }

        XCTAssertEqual(report.issues.count, 3)
        XCTAssertTrue(report.usesEventMonitorFallback)
        XCTAssertEqual(Set(report.issues.map(\.status)), [OSStatus(eventHotKeyExistsErr)])
    }

    func testShortcutPresentationShowsPrimaryAndFallbackKeys() {
        XCTAssertEqual(HotKeyShortcut.defaultQuickScreenshot.displayName, "Fn + Control")
        XCTAssertEqual(HotKeyShortcut.defaultActionCenter.displayName, "Fn + Space")
        XCTAssertEqual(
            HotKeyShortcut.fallbackQuickScreenshot.displayName,
            "Control + Option + 1"
        )
        XCTAssertEqual(
            HotKeyShortcut.fallbackActionCenter.displayName,
            "Control + Option + 2"
        )
    }
}
