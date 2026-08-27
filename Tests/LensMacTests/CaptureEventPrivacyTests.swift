import AppKit
import CoreGraphics
import LensCore
import XCTest
@testable import LensMac

@MainActor
final class CaptureEventPrivacyTests: XCTestCase {
    func testPlainTextAndOptionInputAreNeverRecorded() throws {
        XCTAssertNil(PointerEventRecorder.sanitizedKeyboardEvent(
            from: try keyEvent(characters: "p", modifiers: [], keyCode: 35),
            time: 1
        ))
        XCTAssertNil(PointerEventRecorder.sanitizedKeyboardEvent(
            from: try keyEvent(characters: "π", modifiers: [.option], keyCode: 35),
            time: 2
        ))
    }

    func testShortcutsAndNonTextControlKeysUseSanitizedLabels() throws {
        let shortcut = try XCTUnwrap(PointerEventRecorder.sanitizedKeyboardEvent(
            from: try keyEvent(characters: "p", modifiers: [.command, .shift], keyCode: 35),
            time: 3
        ))
        XCTAssertEqual(shortcut.label, "P")
        XCTAssertEqual(shortcut.modifiers, [.command, .shift])
        XCTAssertEqual(shortcut.keyCode, 35)

        let escape = try XCTUnwrap(PointerEventRecorder.sanitizedKeyboardEvent(
            from: try keyEvent(characters: "\u{1b}", modifiers: [], keyCode: 53),
            time: 4
        ))
        XCTAssertEqual(escape.label, "Escape")
        XCTAssertTrue(escape.modifiers.isEmpty)
    }

    func testPortableEventsNormalizeUnsafeValuesWithoutWindowTitles() {
        let keyboard = KeyboardEvent(
            time: -.infinity,
            keyCode: -4,
            label: "  ",
            modifiers: [.shift, .command, .shift]
        )
        XCTAssertEqual(keyboard.time, 0)
        XCTAssertEqual(keyboard.keyCode, 0)
        XCTAssertNil(keyboard.label)
        XCTAssertEqual(keyboard.modifiers, [.command, .shift])

        let window = WindowEvent(
            time: .nan,
            applicationName: "  Safari  ",
            bundleIdentifier: " com.apple.Safari "
        )
        XCTAssertEqual(window.time, 0)
        XCTAssertEqual(window.applicationName, "Safari")
        XCTAssertEqual(window.bundleIdentifier, "com.apple.Safari")
    }

    func testRecorderWritesOnlySanitizedKeyboardAndApplicationEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensEventRecorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1280, height: 720)
        let recorder = PointerEventRecorder()
        try recorder.start(
            session: session,
            captureBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )

        recorder.handle(try keyEvent(characters: "s", modifiers: [], keyCode: 1))
        recorder.handle(try keyEvent(characters: "s", modifiers: [.command], keyCode: 1))
        recorder.recordApplicationFocus(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: ProcessInfo.processInfo.processIdentifier + 1
        )
        await recorder.stop()

        let keys = try LensEventReader.read(KeyboardEvent.self, from: session.keyboardEventsURL)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.label, "S")
        XCTAssertEqual(keys.first?.modifiers, [.command])
        let applications = try LensEventReader.read(WindowEvent.self, from: session.windowEventsURL)
        XCTAssertTrue(applications.contains {
            $0.applicationName == "Safari" && $0.bundleIdentifier == "com.apple.Safari"
        })
    }

    func testRecorderBridgesBackgroundMonitorEventsAndRejectsStoppedGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensEventBridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1280, height: 720)
        var globalHandler: PointerEventRecorder.GlobalMonitorHandler?
        var removedMonitorCount = 0
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, handler in
                globalHandler = handler
                return NSObject()
            },
            removeMonitorOverride: { _ in removedMonitorCount += 1 }
        )
        try recorder.start(
            session: session,
            captureBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        let callback = try XCTUnwrap(globalHandler)

        await Self.invokeOnBackground(callback)
        await flushMainQueue()
        await recorder.stop()
        await Self.invokeOnBackground(callback)
        await flushMainQueue()

        let keys = try LensEventReader.read(KeyboardEvent.self, from: session.keyboardEventsURL)
        XCTAssertEqual(keys.map(\.label), ["S"])
        XCTAssertEqual(removedMonitorCount, 1)
    }

    func testRecorderPersistsScrollIntentWithoutTreatingItAsTextInput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensScrollRecorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 1280, height: 720)
        let recorder = PointerEventRecorder()
        try recorder.start(
            session: session,
            captureBounds: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -8,
            wheel2: 2,
            wheel3: 0
        ))
        cgEvent.location = CGPoint(x: 640, y: 360)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        recorder.handle(event)
        await recorder.stop()

        let events = try LensEventReader.read(
            PointerEvent.self,
            from: session.pointerEventsURL
        )
        let scroll = try XCTUnwrap(events.first { $0.kind == .scroll })
        let delta = try XCTUnwrap(scroll.scrollDelta)
        XCTAssertEqual(delta.x, 2, accuracy: 0.000_1)
        XCTAssertEqual(delta.y, -8, accuracy: 0.000_1)
    }

    func testWindowRecordingRenormalizesClicksAfterTrackedWindowMoves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensMovedWindow-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LensProjectStore(rootDirectory: root)
        let session = try store.beginRecording(width: 2560, height: 1430)
        let trackedWindowID: CGWindowID = 73
        let staleLogicalBounds = CGRect(x: 0, y: 117, width: 1280, height: 715)
        let onscreenFrameBounds = CGRect(x: 142, y: 47, width: 1088, height: 607.75)
        let recorder = PointerEventRecorder(
            addGlobalMonitorOverride: { _, _ in NSObject() },
            removeMonitorOverride: { _ in },
            windowBoundsProvider: { windowID in
                windowID == trackedWindowID ? staleLogicalBounds : nil
            }
        )
        try recorder.start(
            session: session,
            captureBounds: CGRect(x: 0, y: 117, width: 1280, height: 715),
            trackedWindowID: trackedWindowID
        )
        recorder.updateOnscreenCaptureBounds(onscreenFrameBounds)
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(
                x: onscreenFrameBounds.midX,
                y: onscreenFrameBounds.midY
            ),
            mouseButton: .left
        ))
        cgEvent.setIntegerValueField(.mouseEventClickState, value: 1)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        recorder.handle(event)
        await recorder.stop()

        let clicks = try LensEventReader.read(ClickEvent.self, from: session.clickEventsURL)
        let position = try XCTUnwrap(clicks.first?.normalizedLocation)
        XCTAssertEqual(position.x, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(position.y, 0.5, accuracy: 0.000_1)
    }

    func testWindowBoundsLookupMatchesRequestedWindowInsteadOfFirstEntry() throws {
        let requestedWindowID: CGWindowID = 73
        let unrelatedBounds = CGRect(x: 0, y: 117, width: 1280, height: 715)
        let requestedBounds = CGRect(x: 142, y: 47, width: 1280, height: 715)
        let windowInfo: [[String: Any]] = [
            windowDictionary(id: 9, bounds: unrelatedBounds),
            windowDictionary(id: requestedWindowID, bounds: requestedBounds)
        ]

        XCTAssertEqual(
            PointerEventRecorder.matchingWindowBounds(
                windowID: requestedWindowID,
                in: windowInfo
            ),
            requestedBounds
        )
    }

    private func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func windowDictionary(id: CGWindowID, bounds: CGRect) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds) as NSDictionary
        ]
    }

    nonisolated private static func invokeOnBackground(
        _ callback: @escaping PointerEventRecorder.GlobalMonitorHandler
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                callback(shortcutEvent())
                continuation.resume()
            }
        }
    }

    nonisolated private static func shortcutEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        )!
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
