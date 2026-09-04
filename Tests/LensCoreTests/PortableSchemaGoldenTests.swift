import XCTest
@testable import LensCore
import LensSchemaGoldenKit

/// Guards `shared/golden/` — the cross-language contract for the open `.lens`
/// format. If a portable document changes shape and nobody reruns
/// `swift run lens-schema-golden`, these tests fail here instead of silently
/// breaking a non-Swift implementation.
final class PortableSchemaGoldenTests: XCTestCase {
    private var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LensCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("shared/golden", isDirectory: true)
    }

    private func committedBytes(_ name: String) throws -> Data {
        let url = goldenDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("缺少黄金文件 \(name)；请运行 swift run lens-schema-golden")
            return Data()
        }
        var data = try Data(contentsOf: url)
        // The generator appends a trailing newline for diff friendliness.
        if data.last == UInt8(ascii: "\n") {
            data.removeLast()
        }
        return data
    }

    func testCommittedGoldensMatchCurrentEncoding() throws {
        for document in try PortableSchemaGoldens.all() {
            let committed = try committedBytes(document.name)
            XCTAssertEqual(
                committed,
                document.data,
                """
                \(document.name) 与当前模型编码不一致。
                如果这是有意的 schema 变更，请提升对应的 currentSchemaVersion，
                然后运行 swift run lens-schema-golden 重新生成。
                """
            )
        }
    }

    func testCommittedCompactGoldensMatchCurrentEncoding() throws {
        for document in try PortableSchemaGoldens.allCompact() {
            let committed = try committedBytes(document.name)
            XCTAssertEqual(
                committed,
                document.data,
                "\(document.name) 与当前模型的紧凑编码不一致。"
            )
        }
    }

    /// The compact form is what a Rust/C# implementation can reproduce byte for
    /// byte. Pretty-printed Swift output cannot be (it emits `"key" : value`),
    /// so guard the property the contract actually relies on.
    func testCompactGoldensContainNoPrettyPrintedSeparator() throws {
        for document in try PortableSchemaGoldens.allCompact() {
            let text = String(decoding: document.data, as: UTF8.self)
            XCTAssertFalse(
                text.contains("\" : "),
                "\(document.name) 不应包含 Swift 的 pretty-print 分隔符。"
            )
            XCTAssertFalse(
                text.contains("\\/"),
                "\(document.name) 中的斜杠不应被转义。"
            )
        }
    }

    func testGoldenSchemaVersionsMatchRegistry() throws {
        let expected: [(name: String, version: String)] = [
            ("manifest.json", LensManifest.currentSchemaVersion),
            ("edit-plan.json", AutoEditPlan.currentSchemaVersion),
            ("screenshot-edit.json", ScreenshotEditPlan.currentSchemaVersion),
            ("segments.json", RecordingSegmentIndex.currentSchemaVersion),
            ("scrolling-capture.json", ScrollingCapturePlan.currentSchemaVersion),
            ("ocr.json", OCRDocument.currentSchemaVersion),
            ("transcript.json", TranscriptDocument.currentSchemaVersion),
            ("insights.json", LensInsightsDocument.currentSchemaVersion)
        ]

        for entry in expected {
            let data = try committedBytes(entry.name)
            let object = try JSONSerialization.jsonObject(with: data)
            let dictionary = try XCTUnwrap(object as? [String: Any])
            XCTAssertEqual(
                dictionary["schemaVersion"] as? String,
                entry.version,
                "\(entry.name) 的 schemaVersion 与模型常量不一致。"
            )
        }
    }

    func testSchemaRegistryFileMatchesPortableDocuments() throws {
        let data = try committedBytes("schema-registry.json")
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try XCTUnwrap(object as? [String: Any])
        let documents = try XCTUnwrap(root["documents"] as? [[String: String]])

        XCTAssertEqual(
            documents.count,
            LensProjectSchema.portableDocuments.count,
            "schema-registry.json 的条目数与 portableDocuments 不一致。"
        )

        for (entry, descriptor) in zip(documents, LensProjectSchema.portableDocuments) {
            XCTAssertEqual(entry["identifier"], descriptor.identifier)
            XCTAssertEqual(entry["relativePath"], descriptor.relativePath)
            XCTAssertEqual(
                entry["minimumReadableVersion"],
                descriptor.minimumReadableVersion
            )
            XCTAssertEqual(entry["currentVersion"], descriptor.currentVersion)
        }
    }

    /// Every golden must survive decode → re-encode unchanged. A cross-language
    /// implementation is expected to pass the same check.
    func testGoldensRoundTripThroughTheirModels() throws {
        let encoder = PortableSchemaGoldens.canonicalCompactEncoder()
        let decoder = PortableSchemaGoldens.canonicalDecoder()

        func assertRoundTrip<T: Codable & Equatable>(
            _ type: T.Type,
            _ name: String
        ) throws {
            let data = try committedBytes(name)
            let decoded = try decoder.decode(type, from: data)
            XCTAssertEqual(
                try encoder.encode(decoded),
                data,
                "\(name) 解码后重新编码的字节不一致。"
            )
        }

        try assertRoundTrip(LensManifest.self, "manifest.compact.json")
        try assertRoundTrip(AutoEditPlan.self, "edit-plan.compact.json")
        try assertRoundTrip(ScreenshotEditPlan.self, "screenshot-edit.compact.json")
        try assertRoundTrip(RecordingSegmentIndex.self, "segments.compact.json")
        try assertRoundTrip(ScrollingCapturePlan.self, "scrolling-capture.compact.json")
        try assertRoundTrip(OCRDocument.self, "ocr.compact.json")
        try assertRoundTrip(TranscriptDocument.self, "transcript.compact.json")
        try assertRoundTrip(LensInsightsDocument.self, "insights.compact.json")
    }
}
