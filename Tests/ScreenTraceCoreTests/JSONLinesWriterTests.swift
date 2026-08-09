import Foundation
import XCTest
@testable import ScreenTraceCore

final class JSONLinesWriterTests: XCTestCase {
    func testWriterPersistsOneJSONObjectPerLine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceEvents-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLinesWriter<PointerEvent>(url: url)
        try await writer.append(PointerEvent(
            time: 0.125,
            kind: .moved,
            location: TracePoint(x: 100, y: 200),
            displayID: 7
        ))
        try await writer.append(PointerEvent(
            time: 0.25,
            kind: .dragged,
            location: TracePoint(x: 120, y: 240),
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
}
