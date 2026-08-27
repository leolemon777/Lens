import AppKit
import Carbon
import LensCore
import XCTest
@testable import LensMac

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

        XCTAssertEqual(report.issues.count, 4)
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

    func testSuspendIgnoresHotKeysUntilResume() async throws {
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
        XCTAssertFalse(manager.isSuspended)
        _ = manager.start()
        let activeHandler = try XCTUnwrap(globalHandler)

        await Self.invokeOnBackground(activeHandler)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot])

        manager.suspend()
        XCTAssertTrue(manager.isSuspended)
        XCTAssertEqual(removedMonitorCount, 2)

        await Self.invokeOnBackground(activeHandler)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot])

        manager.suspend()
        XCTAssertEqual(removedMonitorCount, 2)

        _ = manager.resume()
        XCTAssertFalse(manager.isSuspended)
        let resumedHandler = try XCTUnwrap(globalHandler)
        await Self.invokeOnBackground(resumedHandler)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot, .quickScreenshot])

        _ = manager.resume()
        await Self.invokeOnBackground(resumedHandler)
        await flushMainQueue()
        XCTAssertEqual(receivedIntents, [.quickScreenshot, .quickScreenshot, .quickScreenshot])

        manager.stop()
    }

    func testNativeHotKeyIsIgnoredWhileSuspended() {
        var receivedIntents: [HotKeyIntent] = []
        var registeredIdentifiers: [UInt32] = []
        let manager = GlobalHotKeyManager(
            configuration: HotKeyConfiguration(
                quickScreenshot: HotKeyShortcut(keyCode: 6, modifiers: [.command]),
                actionCenter: .defaultActionCenter
            ),
            installEventHandlerOverride: { true },
            registerOverride: { _, identifier in
                registeredIdentifiers.append(identifier)
                return noErr
            },
            addGlobalMonitorOverride: { _, _ in NSObject() },
            addLocalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            handler: { receivedIntents.append($0) }
        )
        _ = manager.start()
        XCTAssertFalse(registeredIdentifiers.isEmpty)

        manager.handleNativeHotKey(identifier: registeredIdentifiers[0])
        XCTAssertEqual(receivedIntents, [.quickScreenshot])

        manager.suspend()
        manager.handleNativeHotKey(identifier: registeredIdentifiers[0])
        XCTAssertEqual(receivedIntents, [.quickScreenshot])

        _ = manager.resume()
        manager.handleNativeHotKey(identifier: registeredIdentifiers[0])
        XCTAssertEqual(receivedIntents, [.quickScreenshot, .quickScreenshot])
        manager.stop()
    }

    func testShortcutPresentationShowsPrimaryAndFallbackKeys() {
        XCTAssertEqual(HotKeyShortcut.defaultQuickScreenshot.displayName, "Fn + Control")
        XCTAssertEqual(HotKeyShortcut.defaultActionCenter.displayName, "Fn + Space")
        XCTAssertEqual(HotKeyShortcut.defaultConversationInbox.displayName, "Fn + Command")
        XCTAssertEqual(
            HotKeyShortcut.fallbackQuickScreenshot.displayName,
            "Control + Option + 1"
        )
        XCTAssertEqual(
            HotKeyShortcut.fallbackActionCenter.displayName,
            "Control + Option + 2"
        )
        XCTAssertEqual(
            HotKeyShortcut.fallbackConversationInbox.displayName,
            "Control + Option + 3"
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
