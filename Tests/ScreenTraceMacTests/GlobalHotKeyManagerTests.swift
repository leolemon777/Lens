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

    func testGlobalMonitorBridgesBackgroundEventsAndRejectsStoppedGeneration() async throws {
        var globalHandler: GlobalHotKeyManager.GlobalMonitorHandler?
        var receivedIntents: [HotKeyIntent] = []
        var removedMonitorCount = 0
        let manager = GlobalHotKeyManager(
            configuration: .default,
            installEventHandlerOverride: { false },
            addGlobalMonitorOverride: { _, handler in
                globalHandler = handler
                return NSObject()
            },
            addLocalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in removedMonitorCount += 1 },
            handler: { receivedIntents.append($0) }
        )
        let report = manager.start()
        let callback = try XCTUnwrap(globalHandler)

        XCTAssertTrue(report.usesEventMonitorFallback)
        await Self.invokeOnBackground(callback)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot])
        await Self.invokeModifierOnlyOnBackground(callback)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot, .quickScreenshot])

        manager.stop()
        await Self.invokeOnBackground(callback)
        await flushMainQueue()

        XCTAssertEqual(receivedIntents, [.quickScreenshot, .quickScreenshot])
        XCTAssertEqual(removedMonitorCount, 2)
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

    nonisolated private static func fallbackScreenshotEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        )!
    }

    nonisolated private static func invokeOnBackground(
        _ callback: @escaping GlobalHotKeyManager.GlobalMonitorHandler
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                callback(fallbackScreenshotEvent())
                continuation.resume()
            }
        }
    }

    nonisolated private static func invokeModifierOnlyOnBackground(
        _ callback: @escaping GlobalHotKeyManager.GlobalMonitorHandler
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let event = NSEvent.keyEvent(
                    with: .flagsChanged,
                    location: .zero,
                    modifierFlags: [.function, .control],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "",
                    charactersIgnoringModifiers: "",
                    isARepeat: false,
                    keyCode: 63
                )!
                callback(event)
                continuation.resume()
            }
        }
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
