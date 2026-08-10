import AppKit
import ScreenTraceCore
import XCTest
@testable import ScreenTraceMac

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
            .appendingPathComponent("ScreenTraceEventRecorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TraceProjectStore(rootDirectory: root)
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

        let keys = try TraceEventReader.read(KeyboardEvent.self, from: session.keyboardEventsURL)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.label, "S")
        XCTAssertEqual(keys.first?.modifiers, [.command])
        let applications = try TraceEventReader.read(WindowEvent.self, from: session.windowEventsURL)
        XCTAssertTrue(applications.contains {
            $0.applicationName == "Safari" && $0.bundleIdentifier == "com.apple.Safari"
        })
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
}
