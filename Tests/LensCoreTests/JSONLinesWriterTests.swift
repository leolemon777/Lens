import Foundation
import XCTest
@testable import LensCore

final class JSONLinesWriterTests: XCTestCase {
    func testWriterPersistsOneJSONObjectPerLine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensEvents-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLinesWriter<PointerEvent>(url: url)
        try await writer.append(PointerEvent(
            time: 0.125,
            kind: .moved,
            location: LensPoint(x: 100, y: 200),
            displayID: 7
        ))
        try await writer.append(PointerEvent(
            time: 0.25,
            kind: .dragged,
            location: LensPoint(x: 120, y: 240),
            displayID: 7
        ))
        try await writer.close()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        let decoded = try lines.map { try decoder.decode(PointerEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map(\.kind), [.moved, .dragged])
    }

    func testPrivacyReducedKeyboardAndWindowTracksRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensEvents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyboardURL = directory.appendingPathComponent("keyboard.jsonl")
        let windowsURL = directory.appendingPathComponent("windows.jsonl")

        let keyboard = KeyboardEvent(
            time: 1.25,
            keyCode: 8,
            label: "C",
            modifiers: [.command]
        )
        let window = WindowEvent(
            time: 2.5,
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        let keyboardWriter = try JSONLinesWriter<KeyboardEvent>(url: keyboardURL)
        let windowWriter = try JSONLinesWriter<WindowEvent>(url: windowsURL)
        try await keyboardWriter.append(keyboard)
        try await windowWriter.append(window)
        try await keyboardWriter.close()
        try await windowWriter.close()

        XCTAssertEqual(try LensEventReader.read(KeyboardEvent.self, from: keyboardURL), [keyboard])
        XCTAssertEqual(try LensEventReader.read(WindowEvent.self, from: windowsURL), [window])
        XCTAssertFalse(
            try String(contentsOf: windowsURL, encoding: .utf8).contains("windowTitle")
        )
    }
}
